"""
Oct container tuned for Particles




"""

#-----------------------------------------------------------------------------
# Copyright (c) 2013, yt Development Team.
#
# Distributed under the terms of the Modified BSD License.
#
# The full license is in the file COPYING.txt, distributed with this software.
#-----------------------------------------------------------------------------

from oct_container cimport OctreeContainer, Oct, OctInfo, ORDER_MAX, \
    SparseOctreeContainer, OctKey, OctAllocationContainer
cimport oct_visitors
from oct_visitors cimport cind
from libc.stdlib cimport malloc, free, qsort
from libc.math cimport floor, ceil, fmod
from yt.utilities.lib.fp_utils cimport *
from yt.utilities.lib.geometry_utils cimport bounded_morton, \
    bounded_morton_dds, bounded_morton_relative_dds, \
    encode_morton_64bit, decode_morton_64bit, \
    morton_neighbors_coarse, morton_neighbors_refined
import numpy as np
cimport numpy as np
from selection_routines cimport SelectorObject
cimport cython
from collections import defaultdict

from particle_deposit cimport gind
from yt.utilities.lib.ewah_bool_array cimport \
    ewah_bool_array
#from yt.utilities.lib.ewah_bool_wrap cimport \
from ..utilities.lib.ewah_bool_wrap cimport BoolArrayCollection
from libcpp.map cimport map
from libcpp.vector cimport vector
from libcpp.pair cimport pair
from cython.operator cimport dereference, preincrement
import struct
import os

# Changes the container used to store morton indicies for selectors
DEF BoolType = "Bool" 
# If set to 1, ghost zones are added after all selected cells are identified.
# If set to 0, ghost zones are added as cells are selected
DEF GhostsAfter = 0
# If set to 1, only cells at the edge of selectors are given ghost zones
# This has no effect if ghost zones are done at the end
DEF OnlyGhostsAtEdges = 1
# If set to 1, only cells at the edge of selectors are refined
DEF OnlyRefineEdges = 1
# If set to 1, ghost cells are added at the refined level
DEF RefinedGhosts = 1
# If set to 1, ghost cells are added at the refined level reguardless of if the 
# coarse cell containing it is refined in the selector.
# If set to 0, ghost cells are only added at the refined level if the coarse index 
# for the ghost cell is refined in the selector.
DEF RefinedExternalGhosts = 1
# If set to 1, bitmaps are only compressed before looking for files
DEF UseUncompressed = 1
# If set to 1, uncompressed bitmaps are passed around as memory views rather than pointers
# Does not apply if UseUncompressed = 0 (i.e. automatically is 1)
DEF UseUncompressedView = 0
# If Set to 1, file bitmasks are managed by cython
DEF UseCythonBitmasks = 1
# If Set to 1, auto fill child cells for cells
DEF FillChildCellsCoarse = 1
DEF FillChildCellsRefined = 1
# Super to handle any case where you need to know edges
# Must be set to 1 if OnlyGhostsAtEdges, OnlyRefineEdges,
# FillChildCellCoarse, or FilleChildCellRefined is 1
DEF DetectEdges = 1

_bitmask_version = np.uint64(0)

IF BoolType == 'Vector':
    from ..utilities.lib.ewah_bool_wrap cimport SparseUnorderedBitmaskVector as SparseUnorderedBitmask
    from ..utilities.lib.ewah_bool_wrap cimport SparseUnorderedRefinedBitmaskVector as SparseUnorderedRefinedBitmask
ELSE:
    from ..utilities.lib.ewah_bool_wrap cimport SparseUnorderedBitmaskSet as SparseUnorderedBitmask
    from ..utilities.lib.ewah_bool_wrap cimport SparseUnorderedRefinedBitmaskSet as SparseUnorderedRefinedBitmask

IF UseUncompressed == 1:
    from ..utilities.lib.ewah_bool_wrap cimport BoolArrayCollectionUncompressed as BoolArrayColl
ELSE:
    from ..utilities.lib.ewah_bool_wrap cimport BoolArrayCollection as BoolArrayColl

IF UseCythonBitmasks == 1:
    from ..utilities.lib.ewah_bool_wrap cimport FileBitmasks

cdef class ParticleOctreeContainer(OctreeContainer):
    cdef Oct** oct_list
    #The starting oct index of each domain
    cdef np.int64_t *dom_offsets
    cdef public int max_level
    #How many particles do we keep befor refining
    cdef public int n_ref

    def allocate_root(self):
        cdef int i, j, k
        cdef Oct *cur
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    cur = self.allocate_oct()
                    self.root_mesh[i][j][k] = cur

    def __dealloc__(self):
        #Call the freemem ops on every ocy
        #of the root mesh recursively
        cdef int i, j, k
        if self.root_mesh == NULL: return
        for i in range(self.nn[0]):
            if self.root_mesh[i] == NULL: continue
            for j in range(self.nn[1]):
                if self.root_mesh[i][j] == NULL: continue
                for k in range(self.nn[2]):
                    if self.root_mesh[i][j][k] == NULL: continue
                    self.visit_free(self.root_mesh[i][j][k])
        free(self.oct_list)
        free(self.dom_offsets)

    cdef void visit_free(self, Oct *o):
        #Free the memory for this oct recursively
        cdef int i, j, k
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_free(o.children[cind(i,j,k)])
        free(o.children)
        free(o)

    def clear_fileind(self):
        cdef int i, j, k
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    self.visit_clear(self.root_mesh[i][j][k])

    cdef void visit_clear(self, Oct *o):
        #Free the memory for this oct recursively
        cdef int i, j, k
        o.file_ind = 0
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_clear(o.children[cind(i,j,k)])

    def __iter__(self):
        #Get the next oct, will traverse domains
        #Note that oct containers can be sorted
        #so that consecutive octs are on the same domain
        cdef int oi
        cdef Oct *o
        for oi in range(self.nocts):
            o = self.oct_list[oi]
            yield (o.file_ind, o.domain_ind, o.domain)

    def allocate_domains(self, domain_counts):
        pass

    def finalize(self, int domain_id = 0):
        #This will sort the octs in the oct list
        #so that domains appear consecutively
        #And then find the oct index/offset for
        #every domain
        cdef int max_level = 0
        self.oct_list = <Oct**> malloc(sizeof(Oct*)*self.nocts)
        cdef np.int64_t i = 0, lpos = 0
        # Note that we now assign them in the same order they will be visited
        # by recursive visitors.
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    self.visit_assign(self.root_mesh[i][j][k], &lpos,
                                      0, &max_level)
        assert(lpos == self.nocts)
        for i in range(self.nocts):
            self.oct_list[i].domain_ind = i
            self.oct_list[i].domain = domain_id
        self.max_level = max_level

    cdef visit_assign(self, Oct *o, np.int64_t *lpos, int level, int *max_level):
        cdef int i, j, k
        self.oct_list[lpos[0]] = o
        lpos[0] += 1
        max_level[0] = imax(max_level[0], level)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_assign(o.children[cind(i,j,k)], lpos,
                                level + 1, max_level)
        return

    cdef np.int64_t get_domain_offset(self, int domain_id):
        return 0

    cdef Oct* allocate_oct(self):
        #Allocate the memory, set to NULL or -1
        #We reserve space for n_ref particles, but keep
        #track of how many are used with np initially 0
        self.nocts += 1
        cdef Oct *my_oct = <Oct*> malloc(sizeof(Oct))
        my_oct.domain = -1
        my_oct.file_ind = 0
        my_oct.domain_ind = self.nocts - 1
        my_oct.children = NULL
        return my_oct

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def add(self, np.ndarray[np.uint64_t, ndim=1] indices,
            np.uint8_t order = ORDER_MAX):
        #Add this particle to the root oct
        #Then if that oct has children, add it to them recursively
        #If the child needs to be refined because of max particles, do so
        cdef np.int64_t no = indices.shape[0], p
        cdef np.uint64_t index
        cdef int i, level
        cdef int ind[3]
        if self.root_mesh[0][0][0] == NULL: self.allocate_root()
        cdef np.uint64_t *data = <np.uint64_t *> indices.data
        for p in range(no):
            # We have morton indices, which means we choose left and right by
            # looking at (MAX_ORDER - level) & with the values 1, 2, 4.
            level = 0
            index = indices[p]
            if index == FLAG:
                # This is a marker for the index not being inside the domain
                # we're interested in.
                continue
            # Convert morton index to 3D index of octree root
            for i in range(3):
                ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
            cur = self.root_mesh[ind[0]][ind[1]][ind[2]]
            if cur == NULL:
                raise RuntimeError
            # Continue refining the octree until you reach the level of the
            # morton indexing order. Along the way, use prefix to count
            # previous indices at levels in the octree?
            while (cur.file_ind + 1) > self.n_ref:
                if level >= order: break # Just dump it here.
                level += 1
                for i in range(3):
                    ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
                if cur.children == NULL or \
                   cur.children[cind(ind[0],ind[1],ind[2])] == NULL:
                    cur = self.refine_oct(cur, index, level, order)
                    self.filter_particles(cur, data, p, level, order)
                else:
                    cur = cur.children[cind(ind[0],ind[1],ind[2])]
            # If our n_ref is 1, we are always refining, which means we're an
            # index octree.  In this case, we should store the index for fast
            # lookup later on when we find neighbors and the like.
            if self.n_ref == 1:
                cur.file_ind = index
            else:
                cur.file_ind += 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef Oct *refine_oct(self, Oct *o, np.uint64_t index, int level,
                         np.uint8_t order):
        #Allocate and initialize child octs
        #Attach particles to child octs
        #Remove particles from this oct entirely
        cdef int i, j, k
        cdef int ind[3]
        cdef Oct *noct
        # TODO: This does not need to be changed.
        o.children = <Oct **> malloc(sizeof(Oct *)*8)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    noct = self.allocate_oct()
                    noct.domain = o.domain
                    noct.file_ind = 0
                    o.children[cind(i,j,k)] = noct
        o.file_ind = self.n_ref + 1
        for i in range(3):
            ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
        noct = o.children[cind(ind[0],ind[1],ind[2])]
        return noct

    cdef void filter_particles(self, Oct *o, np.uint64_t *data, np.int64_t p,
                               int level, np.uint8_t order):
        # Now we look at the last nref particles to decide where they go.
        # If p: Loops over all previous morton indices
        # If n_ref: Loops over n_ref previous morton indices
        cdef int n = imin(p, self.n_ref)
        cdef np.uint64_t *arr = data + imax(p - self.n_ref, 0)
        cdef np.uint64_t prefix1, prefix2
        # Now we figure out our prefix, which is the oct address at this level.
        # As long as we're actually in Morton order, we do not need to worry
        # about *any* of the other children of the oct.
        prefix1 = data[p] >> (order - level)*3
        for i in range(n):
            prefix2 = arr[i] >> (order - level)*3
            if (prefix1 == prefix2):
                o.file_ind += 1 # Says how many morton indices are in this octant?
        #print ind[0], ind[1], ind[2], o.file_ind, level

    def recursively_count(self):
        #Visit every cell, accumulate the # of cells per level
        cdef int i, j, k
        cdef np.int64_t counts[128]
        for i in range(128): counts[i] = 0
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    if self.root_mesh[i][j][k] != NULL:
                        self.visit(self.root_mesh[i][j][k], counts)
        level_counts = {}
        for i in range(128):
            if counts[i] == 0: break
            level_counts[i] = counts[i]
        return level_counts

    cdef visit(self, Oct *o, np.int64_t *counts, level = 0):
        cdef int i, j, k
        counts[level] += 1
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit(o.children[cind(i,j,k)], counts, level + 1)
        return

ctypedef fused anyfloat:
    np.float32_t
    np.float64_t

cdef np.uint64_t ONEBIT=1
cdef np.uint64_t FLAG = ~(<np.uint64_t>0)

cdef class ParticleBitmap:
    cdef np.float64_t left_edge[3]
    cdef np.float64_t right_edge[3]
    cdef np.float64_t dds[3]
    cdef np.float64_t dds_mi1[3]
    cdef np.float64_t dds_mi2[3]
    cdef np.float64_t idds[3]
    cdef np.int32_t dims[3]
    cdef public np.uint64_t nfiles
    cdef int oref
    cdef public int n_ref
    cdef public np.int32_t index_order1
    cdef public np.int32_t index_order2
    cdef public object masks
    cdef public object counts
    cdef public object max_count
    cdef public object owners
    cdef public object _last_selector
    cdef public object _last_return_values
    cdef public object _cached_octrees
    cdef public object _last_octree_subset
    cdef public object _last_oct_handler
    cdef np.uint32_t *file_markers
    cdef np.uint64_t n_file_markers
    cdef np.uint64_t file_marker_i
    IF UseCythonBitmasks == 1:
        cdef FileBitmasks bitmasks
    ELSE:
        cdef BoolArrayCollection[:] bitmasks
    cdef public BoolArrayCollection collisions

    def __init__(self, left_edge, right_edge, nfiles, oref = 1,
                 n_ref = 64, index_order1 = None, index_order2 = None):
        # TODO: Set limit on maximum orders?
        if index_order1 is None: index_order1 = 7
        if index_order2 is None: index_order2 = 5
        cdef int i
        self._cached_octrees = {}
        self._last_selector = None
        self._last_return_values = None
        self._last_octree_subset = None
        self._last_oct_handler = None
        self.oref = oref
        self.nfiles = nfiles
        self.n_ref = n_ref
        for i in range(3):
            self.left_edge[i] = left_edge[i]
            self.right_edge[i] = right_edge[i]
            self.dims[i] = (1<<index_order1)
            self.dds[i] = (right_edge[i] - left_edge[i])/self.dims[i]
            self.idds[i] = 1.0/self.dds[i] 
            self.dds_mi1[i] = (right_edge[i] - left_edge[i]) / (1<<index_order1)
            self.dds_mi2[i] = self.dds_mi1[i] / (1<<index_order2)
        # We use 64-bit masks
        self.index_order1 = index_order1
        self.index_order2 = index_order2
        # This will be an on/off flag for which morton index values are touched
        # by particles.
        # This is the simple way, for now.
        self.masks = np.zeros((1 << (index_order1 * 3), nfiles), dtype="uint8")
        self.owners = np.zeros((1 << (index_order1 * 3), 3), dtype='uint32')
        IF UseCythonBitmasks == 1:
            self.bitmasks = FileBitmasks(self.nfiles)
        ELSE:
            cdef np.ndarray[object, ndim=1] bitmasks
            bitmasks = np.array([BoolArrayCollection() for i in range(nfiles)],
                                dtype="object")
            self.bitmasks = bitmasks
        self.collisions = BoolArrayCollection()

    def _bitmask_logicaland(self, ifile, bcoll, out):
        IF UseCythonBitmasks == 1:
            self.bitmasks._logicaland(ifile, bcoll, out)
        ELSE:
            cdef BoolArrayCollection bitmasks = self.bitmasks[ifile]
            return bitmasks._logicaland(bcoll, out)

    def _bitmask_intersects(self, ifile, bcoll):
        IF UseCythonBitmasks == 1:
            return self.bitmasks._intersects(ifile, bcoll)
        ELSE:
            cdef BoolArrayCollection bitmasks = self.bitmasks[ifile]
            return bitmasks._intersects(bcoll)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def _coarse_index_data_file(self, np.ndarray[anyfloat, ndim=2] pos,
                                np.uint64_t file_id):
        return self.__coarse_index_data_file(pos, file_id)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void __coarse_index_data_file(self, np.ndarray[anyfloat, ndim=2] pos,
                                       np.uint64_t file_id):
        # Initialize
        cdef np.uint64_t i
        cdef np.int64_t p
        cdef np.uint64_t mi
        cdef np.float64_t ppos[3]
        cdef int skip
        cdef np.float64_t LE[3]
        cdef np.float64_t RE[3]
        cdef np.float64_t dds[3]
        cdef np.int32_t order = self.index_order1
        cdef np.int64_t total_hits = 0
        IF UseCythonBitmasks == 1:
            cdef FileBitmasks bitmasks = self.bitmasks
        ELSE:
            cdef BoolArrayCollection bitmasks = self.bitmasks[file_id]
        cdef np.ndarray[np.uint8_t, ndim=1] mask = self.masks[:,file_id]
        # Copy over things for this file (type cast necessary?)
        for i in range(3):
            LE[i] = self.left_edge[i]
            RE[i] = self.right_edge[i]
            dds[i] = self.dds_mi1[i]
        # Mark index of particles that are in this file
        for p in range(pos.shape[0]):
            skip = 0
            for i in range(3):
                # Skip particles outside the domain
                if pos[p,i] > RE[i] or pos[p,i] < LE[i]:
                    skip = 1
                    break
                ppos[i] = pos[p,i]
            if skip==1: continue
            mi = bounded_morton_dds(ppos[0], ppos[1], ppos[2], LE, dds)
            mask[mi] = 1
        # Add in order
        for i in range(mask.shape[0]):
            if mask[i] == 1:
                IF UseCythonBitmasks:
                    bitmasks._set_coarse(file_id, i)
                ELSE:
                    bitmasks._set_coarse(<np.uint64_t>i)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def _refined_index_data_file(self, np.ndarray[anyfloat, ndim=2] pos, 
                                 np.ndarray[np.uint8_t, ndim=1] mask,
                                 np.ndarray[np.uint64_t, ndim=1] sub_mi1,
                                 np.ndarray[np.uint64_t, ndim=1] sub_mi2,
                                 np.uint64_t file_id):
        return self.__refined_index_data_file(pos, mask, sub_mi1, sub_mi2, file_id)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef np.uint64_t __refined_index_data_file(self, np.ndarray[anyfloat, ndim=2] pos, 
                                               np.ndarray[np.uint8_t, ndim=1] mask,
                                               np.ndarray[np.uint64_t, ndim=1] sub_mi1,
                                               np.ndarray[np.uint64_t, ndim=1] sub_mi2,
                                               np.uint64_t file_id):
        # Initialize
        cdef np.uint64_t i, p, mi, nsub_mi#, last_mi, last_submi
        cdef np.float64_t ppos[3]
        cdef int skip
        cdef np.float64_t LE[3]
        cdef np.float64_t RE[3]
        cdef np.float64_t dds1[3]
        cdef np.float64_t dds2[3]
        cdef np.int32_t order1 = self.index_order1
        cdef np.int32_t order2 = self.index_order2
        cdef np.ndarray[np.uint32_t, ndim=1] pcount = np.zeros(1 << (order1**3), dtype='uint32')
        cdef np.ndarray[np.uint32_t, ndim=2] owners = self.owners
        IF UseCythonBitmasks == 1:
            cdef FileBitmasks bitmasks = self.bitmasks
        ELSE:
            cdef BoolArrayCollection bitmasks = self.bitmasks[file_id]
        # cdef ewah_bool_array total_refn = (<ewah_bool_array*> self.collisions.ewah_refn)[0]
        # Copy things from structure (type cast)
        for i in range(3):
            LE[i] = self.left_edge[i]
            RE[i] = self.right_edge[i]
            dds1[i] = self.dds_mi1[i]
            dds2[i] = self.dds_mi2[i]
        nsub_mi = 0
        # Loop over positions skipping those outside the domain
        for p in range(pos.shape[0]):
            skip = 0
            for i in range(3):
                if pos[p,i] > RE[i] or pos[p,i] < LE[i]:
                    skip = 1
                    break
                ppos[i] = pos[p,i]
            if skip==1: continue
            # Only look if collision at coarse index
            mi = bounded_morton_dds(ppos[0], ppos[1], ppos[2], LE, dds1)
            #if total_refn.get(mi): 
            if mask[mi] > 1:
                # Determine sub index within cell of primary index
                sub_mi1[nsub_mi] = mi
                sub_mi2[nsub_mi] = bounded_morton_relative_dds(ppos[0], ppos[1], ppos[2],
                                                               LE, dds1, dds2)
                nsub_mi += 1
                pcount[mi] += 1
                if pcount[mi] > owners[mi][0]:
                    owners[mi][0] = pcount[mi]
                    owners[mi][1] = file_id
            else:
                owners[mi][1] = file_id
                owners[mi][2] += 1
        # Only subs of particles in the mask
        sub_mi1 = sub_mi1[:nsub_mi]
        sub_mi2 = sub_mi2[:nsub_mi]
        cdef np.ndarray[np.int64_t, ndim=1] ind = np.lexsort((sub_mi2,sub_mi1))
        # cdef np.ndarray[np.int64_t, ndim=1] ind = np.argsort(sub_mi2[:nsub_mi])
        # last_submi = last_mi = 0
        for i in range(nsub_mi):
            p = ind[i]
            # Make sure its sorted by second index
            # if not (sub_mi2[p] >= last_submi):
            #     print(last_mi, last_submi, sub_mi1[p], sub_mi2[p])
            #     raise RuntimeError("Error in sort by refined index.")
            # if last_mi == sub_mi1[p]:
            #     last_submi = sub_mi2[p]
            # else:
            #     last_submi = 0
            # last_mi = sub_mi1[p]
            # Set bitmasks
            IF UseCythonBitmasks == 1:
                bitmasks._set_refined(file_id, sub_mi1[p], sub_mi2[p])
            ELSE:
                bitmasks._set_refined(sub_mi1[p], sub_mi2[p])
        return nsub_mi

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def _owners_data_file(self, np.ndarray[anyfloat, ndim=2] pos, 
                          np.uint64_t file_id):
        return self.__owners_data_file(pos, file_id)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef np.uint64_t __owners_data_file(self, np.ndarray[anyfloat, ndim=2] pos, 
                                        np.uint64_t file_id):
        # Initialize
        cdef np.uint64_t i, p, mi
        cdef np.float64_t ppos[3]
        cdef int skip
        cdef np.float64_t LE[3]
        cdef np.float64_t RE[3]
        cdef np.float64_t dds1[3]
        cdef np.int32_t order1 = self.index_order1
        cdef np.ndarray[np.uint32_t, ndim=1] pcount = np.zeros(1 << (order1**3), dtype='uint32')
        cdef np.ndarray[np.uint32_t, ndim=2] owners = self.owners
        cdef bint isref
        IF UseCythonBitmasks == 1:
            cdef FileBitmasks bitmasks = self.bitmasks
        ELSE:
            cdef BoolArrayCollection bitmasks = self.bitmasks[file_id]
        # Copy things from structure (type cast)
        for i in range(3):
            LE[i] = self.left_edge[i]
            RE[i] = self.right_edge[i]
            dds1[i] = self.dds_mi1[i]
        # Loop over positions skipping those outside the domain
        for p in range(pos.shape[0]):
            skip = 0
            for i in range(3):
                if pos[p,i] > RE[i] or pos[p,i] < LE[i]:
                    skip = 1
                    break
                ppos[i] = pos[p,i]
            if skip==1: continue
            # Only look if collision at coarse index
            mi = bounded_morton_dds(ppos[0], ppos[1], ppos[2], LE, dds1)
            IF UseCythonBitmasks == 1:
                isref = bitmasks._isref(file_id, mi)
            ELSE:
                isref = bitmasks._isref(mi)
            if isref:
                pcount[mi] += 1
                if pcount[mi] > owners[mi][0]:
                    owners[mi][0] = pcount[mi]
                    owners[mi][1] = file_id
            else:
                owners[mi][1] = file_id
                owners[mi][2] += 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def set_owners(self):
        cdef np.ndarray[np.uint32_t, ndim=2] owners = self.owners
        IF UseCythonBitmasks == 1:
            self.bitmasks._set_owners(owners)
        ELSE:
            cdef np.uint64_t i1
            cdef np.uint32_t ifile
            cdef BoolArrayCollection bitmask
            for i1 in range(owners.shape[0]):
                if owners[i1][0] > 0:
                    ifile = owners[i1][1]
                    bitmask = self.bitmasks[ifile]
                    bitmask._set_owns(i1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def find_collisions(self, verbose=True):
        cdef tuple cc, rc
        IF UseCythonBitmasks == 1:
            cc, rc = self.bitmasks._find_collisions(self.collisions,verbose)
        ELSE:
            cc = self.find_collisions_coarse(verbose=verbose)
            rc = self.find_collisions_refined(verbose=verbose)
        return cc, rc

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def find_collisions_coarse(self, verbose=True, file_list = None):
        cdef int nc, nm
        IF UseCythonBitmasks == 1:
            nc, nm = self.bitmasks._find_collisions_coarse(self.collisions, verbose, file_list)
        ELSE:
            cdef ewah_bool_array* coll_keys
            cdef ewah_bool_array* coll_refn
            cdef np.int32_t ifile
            cdef BoolArrayCollection bitmask
            cdef ewah_bool_array arr_two, arr_swap, arr_keys, arr_refn
            coll_keys = (<ewah_bool_array*> self.collisions.ewah_keys)
            coll_refn = (<ewah_bool_array*> self.collisions.ewah_refn)
            if file_list is None:
                file_list = range(self.nfiles)
            for ifile in file_list:
                bitmask = self.bitmasks[ifile]
                arr_keys.logicaland((<ewah_bool_array*> bitmask.ewah_keys)[0], arr_two)
                arr_keys.logicalor((<ewah_bool_array*> bitmask.ewah_keys)[0], arr_swap)
                arr_keys.swap(arr_swap)
                arr_refn.logicalor(arr_two, arr_swap)
                arr_refn.swap(arr_swap)
            coll_keys[0].swap(arr_keys)
            coll_refn[0].swap(arr_refn)
            nc = coll_refn[0].numberOfOnes()
            nm = coll_keys[0].numberOfOnes()
            if verbose:
                print("{: 10d}/{: 10d} collisions at coarse refinement.  ({: 10.5f}%)".format(nc,nm,100.0*float(nc)/nm))
        return nc, nm

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def find_uncontaminated(self, mask, ifile):
        cdef np.ndarray[np.uint8_t, ndim=1] arr = np.zeros((1 << (self.index_order1 * 3)),'uint8')
        cdef np.uint8_t[:] arr_view = arr
        IF UseCythonBitmasks == 1:
            self.bitmasks._select_uncontaminated(ifile, mask, arr_view)
        ELSE:
            cdef BoolArrayCollection bitmask = self.bitmasks[ifile]
            bitmask._select_uncontaminated(mask, arr_view)
        return arr

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def find_contaminated(self, mask, ifile):
        cdef np.ndarray[np.uint8_t, ndim=1] arr = np.zeros((1 << (self.index_order1 * 3)),'uint8')
        cdef np.uint8_t[:] arr_view = arr
        IF UseCythonBitmasks == 1:
            self.bitmasks._select_contaminated(ifile, mask, arr_view)
        ELSE:
            cdef BoolArrayCollection bitmask = self.bitmasks[ifile]
            bitmask._select_contaminated(mask, arr_view)
        return arr

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    def find_collisions_refined(self, verbose=True):
        cdef np.int32_t nc, nm
        IF UseCythonBitmasks == 1:
            nc, nm = self.bitmasks._find_collisions_refined(self.collisions,verbose)
        ELSE:
            cdef map[np.uint64_t, ewah_bool_array].iterator it_mi1
            cdef np.int32_t ifile
            cdef BoolArrayCollection bitmask
            cdef ewah_bool_array iarr, arr_two, arr_swap
            cdef ewah_bool_array* coll_refn
            cdef map[np.uint64_t, ewah_bool_array] map_bitmask, map_keys, map_refn
            cdef map[np.uint64_t, ewah_bool_array]* coll_coll
            coll_refn = <ewah_bool_array*> self.collisions.ewah_refn
            if coll_refn[0].numberOfOnes() == 0:
                if verbose:
                    print("{: 10d}/{: 10d} collisions at refined refinement. ({: 10.5f}%)".format(0,0,0))
                return (0,0)
            coll_coll = (<map[np.uint64_t, ewah_bool_array]*> self.collisions.ewah_coll)
            for ifile in range(self.nfiles):
                bitmask = self.bitmasks[ifile]
                map_bitmask = (<map[np.uint64_t, ewah_bool_array]*> bitmask.ewah_coll)[0]
                it_mi1 = map_bitmask.begin()
                while it_mi1 != map_bitmask.end():
                    mi1 = dereference(it_mi1).first
                    iarr = dereference(it_mi1).second
                    map_keys[mi1].logicaland(iarr, arr_two)
                    map_keys[mi1].logicalor(iarr, arr_swap)
                    map_keys[mi1].swap(arr_swap)
                    map_refn[mi1].logicalor(arr_two, arr_swap)
                    map_refn[mi1].swap(arr_swap)
                    preincrement(it_mi1)
            coll_coll[0] = map_refn
            # Add them up
            if verbose:
                nc = 0
                nm = 0
                it_mi1 = map_refn.begin()
                while it_mi1 != map_refn.end():
                    mi1 = dereference(it_mi1).first
                    iarr = dereference(it_mi1).second
                    nc += iarr.numberOfOnes()
                    IF UseCythonBitmasks == 0:
                        iarr = map_keys[mi1]
                        nm += iarr.numberOfOnes()
                    preincrement(it_mi1)
                if nm == 0:
                    print("{: 10d}/{: 10d} collisions at refined refinement. ({: 10.5f}%)".format(nc,nm,0))
                else:
                    print("{: 10d}/{: 10d} collisions at refined refinement. ({: 10.5f}%)".format(nc,nm,100.0*float(nc)/nm))
        return nc, nm

    def calcsize_bitmasks(self):
        # TODO: All cython
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection b1
        cdef bytes serial_BAC
        cdef int ifile
        cdef int out = 0
        out += struct.calcsize('Q')
        # Bitmaps for each file
        for ifile in range(self.nfiles):
            IF UseCythonBitmasks == 1:
                serial_BAC = self.bitmasks._dumps(ifile)
            ELSE:
                b1 = self.bitmasks[ifile]
                serial_BAC = b1._dumps()
            out += struct.calcsize('Q')
            out += len(serial_BAC)
        # Bitmap for collisions
        serial_BAC = self.collisions._dumps()
        out += struct.calcsize('Q')
        out += len(serial_BAC)
        return out

    def get_bitmasks(self):
        return self.bitmasks

    def iseq_bitmask(self, solf):
        IF UseCythonBitmasks == 1:
            return self.bitmasks._iseq(solf.get_bitmasks())
        ELSE:
            cdef BoolArrayCollection b1
            cdef BoolArrayCollection b2
            cdef int ifile
            if solf.nfiles != self.nfiles:
                return 0
            for ifile in range(self.nfiles):
                b1 = self.bitmasks[ifile]
                b2 = solf.get_bitmasks()[ifile]
                if b1 != b2:
                    return 0
            return 1

    def save_bitmasks(self,fname):
        cdef bytes serial_BAC
        cdef int ifile
        f = open(fname,'wb')
        # Header
        f.write(struct.pack('Q',_bitmask_version))
        f.write(struct.pack('Q',self.nfiles))
        # Bitmap for each file
        IF UseCythonBitmasks == 1:
            for ifile in range(self.nfiles):
                serial_BAC = self.bitmasks._dumps(ifile)
                f.write(struct.pack('Q',len(serial_BAC)))
                f.write(serial_BAC)

        ELSE:
            cdef BoolArrayCollection b1
            for ifile in range(self.nfiles):
                b1 = self.bitmasks[ifile]
                serial_BAC = b1._dumps()
                f.write(struct.pack('Q',len(serial_BAC)))
                f.write(serial_BAC)
        # Collisions
        serial_BAC = self.collisions._dumps()
        f.write(struct.pack('Q',len(serial_BAC)))
        f.write(serial_BAC)
        f.close()

    def load_bitmasks(self,fname):
        cdef bint read_flag = 1
        cdef bint irflag
        cdef np.uint64_t ver
        cdef np.uint64_t nfiles = 0
        cdef np.uint64_t size_serial
        cdef bint overwrite = 0
        # Verify that file is correct version
        if not os.path.isfile(fname):
            raise IOError("The provided index file does not exist")
        f = open(fname,'rb')
        ver, = struct.unpack('Q',f.read(struct.calcsize('Q')))
        if ver == self.nfiles and ver != _bitmask_version:
            overwrite = 1
            nfiles = ver
            ver = 0 # Original bitmaps had number of files first
        if ver != _bitmask_version:
            raise IOError("The file format of the index has changed since "+
                          "this file was created. It will be replaced with an "+
                          "updated version.")
        # Read number of bitmaps
        if nfiles == 0:
            nfiles, = struct.unpack('Q',f.read(struct.calcsize('Q')))
            if nfiles != self.nfiles:
                raise Exception("Number of bitmasks ({}) conflicts with number of files ({})".format(nfiles,self.nfiles))
        # Read bitmap for each file
        IF UseCythonBitmasks == 1:
            for ifile in range(nfiles):
                size_serial, = struct.unpack('Q',f.read(struct.calcsize('Q')))
                irflag = self.bitmasks._loads(ifile, f.read(size_serial))
                if irflag == 0: read_flag = 0
        ELSE:
            cdef BoolArrayCollection b1
            for ifile in range(nfiles):
                b1 = self.bitmasks[ifile]
                size_serial, = struct.unpack('Q',f.read(struct.calcsize('Q')))
                irflag = b1._loads(f.read(size_serial))
                if irflag == 0: read_flag = 0
        # Collisions
        size_serial, = struct.unpack('Q',f.read(struct.calcsize('Q')))
        irflag = self.collisions._loads(f.read(size_serial))
        f.close()
        # Save in correct format
        if overwrite == 1:
            self.save_bitmasks(fname)
        return read_flag

    def check(self):
        cdef np.uint64_t mi1
        cdef ewah_bool_array arr_totref, arr_tottwo
        cdef ewah_bool_array arr, arr_any, arr_two, arr_swap
        cdef vector[size_t] vec_totref
        cdef vector[size_t].iterator it_mi1
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection b1
        cdef int nm = 0, nc = 0
        # Locate all indices with second level refinement
        for ifile in range(self.nfiles):
            IF UseCythonBitmasks == 1:
                arr = (<ewah_bool_array**> self.bitmasks.ewah_refn)[ifile][0]
            ELSE:
                b1 = self.bitmasks[ifile]
                arr = (<ewah_bool_array*> b1.ewah_refn)[0]
            arr_totref.logicalor(arr,arr_totref)
        # Count collections & second level indices
        vec_totref = arr_totref.toArray()
        it_mi1 = vec_totref.begin()
        while it_mi1 != vec_totref.end():
            mi1 = dereference(it_mi1)
            arr_any.reset()
            arr_two.reset()
            for ifile in range(len(self.bitmasks)):
                IF UseCythonBitmasks == 1:
                    if self.bitmasks._isref(ifile, mi1) == 1:
                        arr = (<map[np.int64_t, ewah_bool_array]**> self.bitmasks.ewah_coll)[ifile][0][mi1]
                        arr_any.logicaland(arr, arr_two) # Indices in previous files
                        arr_any.logicalor(arr, arr_swap) # All second level indices
                        arr_any = arr_swap
                        arr_two.logicalor(arr_tottwo,arr_tottwo)
                ELSE:
                    b1 = self.bitmasks[ifile]
                    if b1._isref(mi1) == 1:
                        arr = (<map[np.int64_t, ewah_bool_array]*> b1.ewah_coll)[0][mi1]
                        arr_any.logicaland(arr, arr_two) # Indices in previous files
                        arr_any.logicalor(arr, arr_swap) # All second level indices
                        arr_any = arr_swap
                        arr_two.logicalor(arr_tottwo,arr_tottwo)
            nc += arr_tottwo.numberOfOnes()
            nm += arr_any.numberOfOnes()
            preincrement(it_mi1)
        # nc: total number of second level morton indices that are repeated
        # nm: total number of second level morton indices
        print "Total of %s / %s collisions (% 3.5f%%)" % (nc, nm, 100.0*float(nc)/nm)

    def finalize(self):
        return
        # self.index_octree = ParticleOctreeContainer([1,1,1],
        #     [self.left_edge[0], self.left_edge[1], self.left_edge[2]],
        #     [self.right_edge[0], self.right_edge[1], self.right_edge[2]],
        #     over_refine = 0
        # )
        # self.index_octree.n_ref = 1
        # mi = (<ewah_bool_array*> self.collisions.ewah_keys)[0].toArray() 
        # Change from vector to numpy
        # mi = mi.astype("uint64")
        # self.index_octree.add(mi, self.index_order1)
        # self.index_octree.finalize()

    def get_DLE(self):
        cdef int i
        cdef np.ndarray[np.float64_t, ndim=1] DLE
        DLE = np.zeros(3, dtype='float64')
        for i in range(3):
            DLE[i] = self.left_edge[i]
        return DLE
    def get_DRE(self):
        cdef int i
        cdef np.ndarray[np.float64_t, ndim=1] DRE
        DRE = np.zeros(3, dtype='float64')
        for i in range(3):
            DRE[i] = self.right_edge[i]
        return DRE

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def identify_data_files(self, SelectorObject selector, int ngz = 0):
        cdef BoolArrayCollection cmask_s = BoolArrayCollection()
        cdef BoolArrayCollection cmask_g = BoolArrayCollection()
        # Find mask of selected morton indices
        cdef ParticleBitmapSelector morton_selector
        morton_selector = ParticleBitmapSelector(selector,self,ngz=ngz)
        morton_selector.fill_masks(cmask_s, cmask_g)
        return morton_selector.masks_to_files(cmask_s, cmask_g), (cmask_s, cmask_g)
        # Other version
        # cdef np.ndarray[np.uint8_t, ndim=1] file_mask_p
        # cdef np.ndarray[np.uint8_t, ndim=1] file_mask_g
        # file_mask_p = np.zeros(self.nfiles, dtype="uint8")
        # file_mask_g = np.zeros(self.nfiles, dtype="uint8")
        # morton_selector.find_files(file_mask_p,file_mask_g)
        # cdef np.ndarray[np.int32_t, ndim=1] file_idx_p
        # cdef np.ndarray[np.int32_t, ndim=1] file_idx_g
        # print "After: {}, {}".format(np.sum(file_mask_p>0),np.sum(file_mask_g>0))
        # file_idx_p = np.where(file_mask_p)[0].astype('int32')
        # file_idx_g = np.where(file_mask_g)[0].astype('int32')
        # return file_idx_p, file_idx_g

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def construct_octree(self, SelectorObject selector, 
                         BoolArrayCollection selector_mask,
                         io_handler, data_files):
        cdef np.uint64_t fcheck, fmask
        cdef np.ndarray[np.int32_t, ndim=1] bitmap_nodes
        bitmap_nodes = np.zeros((self.dims[0]*self.dims[1]*self.dims[2]),
            dtype="int32") - 1
        cdef np.uint64_t i, j, k, n, nm, ii, particle_index
        cdef int ind[3]
        nm = len(self.masks)
        cdef np.uint64_t **masks = <np.uint64_t **> malloc(
            sizeof(np.uint64_t *) * nm)
        index = -1
        cdef int dims[3]
        for i in range(3):
            dims[i] = self.dims[i]
        # Now we can actually create a sparse octree.
        cdef np.ndarray[np.uint8_t, ndim=1] uncontaminated 
        uncontaminated = self.find_uncontaminated(selector_mask,
                            data_files[0].file_id)
        cdef ParticleBitmapOctreeContainer octree
        octree = ParticleBitmapOctreeContainer(
            (self.dims[0], self.dims[1], self.dims[2]),
            (self.left_edge[0], self.left_edge[1], self.left_edge[2]),
            (self.right_edge[0], self.right_edge[1], self.right_edge[2]),
            uncontaminated.sum(), self.oref)
        octree.n_ref = self.n_ref
        octree.allocate_domains()
        cdef np.ndarray[np.uint64_t, ndim=1] morton_ind
        # Okay, now just to filter based on our mask.
        cdef np.uint64_t ind64[3]
        cdef np.uint64_t mi
        cdef int arri
        cdef np.ndarray pos
        cdef np.ndarray[np.float32_t, ndim=2] pos32
        cdef np.ndarray[np.float64_t, ndim=2] pos64
        cdef np.float64_t ppos[3]
        cdef np.float64_t DLE[3]
        cdef np.float64_t DRE[3]
        cdef int bitsize = 0
        for i in range(3):
            DLE[i] = self.left_edge[i]
            DRE[i] = self.right_edge[i]
        for i in range(uncontaminated.size):
            if uncontaminated[i] != 1: continue
            decode_morton_64bit(<np.uint64_t> i, ind64)
            for j in range(3):
                ind[j] = ind64[j]
            octree.next_root(1, ind)
        assert(len(data_files) == 1)
        for data_file in data_files:
            morton_ind = np.empty(sum(data_file.total_particles.values()), dtype="uint64")
            # We now get our particle positions
            for pos in io_handler._yield_coordinates(data_file):
                pos32 = pos64 = None
                bitsize = 0
                if pos.dtype == np.float32:
                    pos32 = pos
                    bitsize = 32
                elif pos.dtype == np.float64:
                    pos64 = pos
                    bitsize = 64
                else:
                    raise RuntimeError
                for j in range(pos.shape[0]):
                    # First we get our cell index.
                    for k in range(3):
                        if bitsize == 32:
                            ppos[k] = pos32[j,k]
                        else:
                            ppos[k] = pos64[j,k]
                        ind[k] = <int> ((ppos[k] - self.left_edge[k])*self.idds[k])
                    mi = bounded_morton(ppos[0], ppos[1], ppos[2], DLE, DRE,
                                        ORDER_MAX)
                    morton_ind[j] = mi
        morton_ind.sort()
        octree.add(morton_ind, self.index_order1)
        octree.finalize()
        return octree

cdef class ParticleBitmapSelector:
    cdef SelectorObject selector
    cdef ParticleBitmap bitmap
    cdef np.uint32_t ngz
    cdef np.float64_t DLE[3]
    cdef np.float64_t DRE[3]
    cdef bint periodicity[3]
    cdef np.uint32_t order1
    cdef np.uint32_t order2
    cdef np.uint64_t max_index1
    cdef np.uint64_t max_index2
    cdef np.uint64_t s1
    cdef np.uint64_t s2
    IF BoolType == "Bool":
        cdef void* pointers[11]
    ELSE:
        cdef void* pointers[7]
    cdef np.uint64_t[:,:] ind1_n
    cdef np.uint64_t[:,:] ind2_n
    cdef np.uint32_t[:,:] neighbors
    cdef np.uint64_t[:] neighbor_list1
    cdef np.uint64_t[:] neighbor_list2
    cdef np.uint32_t nfiles
    cdef np.uint8_t[:] file_mask_p
    cdef np.uint8_t[:] file_mask_g
    # Uncompressed boolean
    IF BoolType == "Bool":
        IF UseUncompressedView == 1:
            cdef np.uint8_t[:] refined_select_bool
            cdef np.uint8_t[:] refined_ghosts_bool
            cdef np.uint8_t[:] coarse_select_bool
            cdef np.uint8_t[:] coarse_ghosts_bool
        ELSE:
            cdef np.uint8_t *refined_select_bool
            cdef np.uint8_t *refined_ghosts_bool
            cdef np.uint8_t *coarse_select_bool
            cdef np.uint8_t *coarse_ghosts_bool
        cdef SparseUnorderedRefinedBitmask refined_ghosts_list
        cdef BoolArrayColl select_ewah
        cdef BoolArrayColl ghosts_ewah
    # Vectors
    ELSE:
        cdef SparseUnorderedBitmask coarse_select_list
        cdef SparseUnorderedBitmask coarse_ghosts_list
        cdef SparseUnorderedRefinedBitmask refined_select_list
        cdef SparseUnorderedRefinedBitmask refined_ghosts_list

    def __cinit__(self, selector, bitmap, ngz=0):
        cdef int i
        cdef np.ndarray[np.uint8_t, ndim=1] periodicity = np.zeros(3, dtype='uint8')
        cdef np.ndarray[np.float64_t, ndim=1] DLE = np.zeros(3, dtype='float64')
        cdef np.ndarray[np.float64_t, ndim=1] DRE = np.zeros(3, dtype='float64')
        self.selector = selector
        self.bitmap = bitmap
        self.ngz = ngz
        # Things from the bitmap & selector
        periodicity = selector.get_periodicity()
        DLE = bitmap.get_DLE()
        DRE = bitmap.get_DRE()
        for i in range(3):
            self.DLE[i] = DLE[i]
            self.DRE[i] = DRE[i]
            self.periodicity[i] = periodicity[i]
        self.order1 = bitmap.index_order1
        self.order2 = bitmap.index_order2
        self.nfiles = bitmap.nfiles
        self.max_index1 = <np.uint64_t>(1 << self.order1)
        self.max_index2 = <np.uint64_t>(1 << self.order2)
        self.s1 = <np.uint64_t>(1 << (self.order1*3))
        self.s2 = <np.uint64_t>(1 << (self.order2*3))
        self.pointers[0] = malloc( sizeof(np.int32_t) * (2*ngz+1)*3)
        self.pointers[1] = malloc( sizeof(np.uint64_t) * (2*ngz+1)*3)
        self.pointers[2] = malloc( sizeof(np.uint64_t) * (2*ngz+1)*3)
        self.pointers[3] = malloc( sizeof(np.uint64_t) * (2*ngz+1)**3)
        self.pointers[4] = malloc( sizeof(np.uint64_t) * (2*ngz+1)**3)
        self.pointers[5] = malloc( sizeof(np.uint8_t) * bitmap.nfiles)
        self.pointers[6] = malloc( sizeof(np.uint8_t) * bitmap.nfiles)
        self.neighbors = <np.uint32_t[:2*ngz+1,:3]> self.pointers[0]
        self.ind1_n = <np.uint64_t[:2*ngz+1,:3]> self.pointers[1]
        self.ind2_n = <np.uint64_t[:2*ngz+1,:3]> self.pointers[2]
        self.neighbor_list1 = <np.uint64_t[:((2*ngz+1)**3)]> self.pointers[3]
        self.neighbor_list2 = <np.uint64_t[:((2*ngz+1)**3)]> self.pointers[4]
        self.file_mask_p = <np.uint8_t[:bitmap.nfiles]> self.pointers[5]
        self.file_mask_g = <np.uint8_t[:bitmap.nfiles]> self.pointers[6]
        self.neighbors[:,:] = 0
        self.file_mask_p[:] = 0
        self.file_mask_g[:] = 0
        # Uncompressed Boolean
        IF BoolType == "Bool":
            self.pointers[7] = malloc( sizeof(np.uint8_t) * self.s2)
            self.pointers[8] = malloc( sizeof(np.uint8_t) * self.s2)
            self.pointers[9] = malloc( sizeof(np.uint8_t) * self.s1)
            self.pointers[10] = malloc( sizeof(np.uint8_t) * self.s1)
            IF UseUncompressedView == 1:
                self.refined_select_bool = <np.uint8_t[:self.s2]> self.pointers[7]
                self.refined_ghosts_bool = <np.uint8_t[:self.s2]> self.pointers[8]
                self.coarse_select_bool = <np.uint8_t[:self.s1]> self.pointers[9]
                self.coarse_ghosts_bool = <np.uint8_t[:self.s1]> self.pointers[10]
                self.refined_select_bool[:] = 0
                self.refined_ghosts_bool[:] = 0
                self.coarse_select_bool[:] = 0
                self.coarse_ghosts_bool[:] = 0
            ELSE:
                self.refined_select_bool = <np.uint8_t *> self.pointers[7]
                self.refined_ghosts_bool = <np.uint8_t *> self.pointers[8]
                self.coarse_select_bool = <np.uint8_t *> self.pointers[9]
                self.coarse_ghosts_bool = <np.uint8_t *> self.pointers[10]
                cdef np.uint64_t mi
                for mi in range(self.s2):
                    self.refined_select_bool[mi] = 0
                    self.refined_ghosts_bool[mi] = 0
                for mi in range(self.s1):
                    self.coarse_select_bool[mi] = 0
                    self.coarse_ghosts_bool[mi] = 0
            self.refined_ghosts_list = SparseUnorderedRefinedBitmask()
            IF UseUncompressed == 1:
                self.select_ewah = BoolArrayColl(self.s1, self.s2)
                self.ghosts_ewah = BoolArrayColl(self.s1, self.s2)
            ELSE:
                self.select_ewah = BoolArrayCollection()
                self.ghosts_ewah = BoolArrayCollection()
        # Vectors
        ELSE:
            self.coarse_select_list = SparseUnorderedBitmask()
            self.coarse_ghosts_list = SparseUnorderedBitmask()
            self.refined_select_list = SparseUnorderedRefinedBitmask()
            self.refined_ghosts_list = SparseUnorderedRefinedBitmask()

    def __dealloc__(self):
        cdef int i
        IF BoolType == 'Bool':
            for i in range(11):
                free(self.pointers[i])
        ELSE:
            for i in range(7):
                free(self.pointers[i])

    def fill_masks(self, BoolArrayCollection mm_s, BoolArrayCollection mm_g):
        # Normal variables
        cdef int i
        cdef np.int32_t level = 0
        cdef np.uint64_t mi1
        mi1 = ~(<np.uint64_t>0)
        cdef np.float64_t pos[3]
        cdef np.float64_t dds[3]
        for i in range(3):
            pos[i] = self.DLE[i]
            dds[i] = self.DRE[i] - self.DLE[i]
        # Uncompressed version
        cdef BoolArrayColl mm_s0
        cdef BoolArrayColl mm_g0
        IF UseUncompressed == 1:
            mm_s0 = BoolArrayColl(self.s1, self.s2)
            mm_g0 = BoolArrayColl(self.s1, self.s2)
        ELSE:
            mm_s0 = mm_s
            mm_g0 = mm_g
        # Recurse
        IF FillChildCellsCoarse == 1:
            cdef np.float64_t rpos[3]
            for i in range(3):
                rpos[i] = self.DRE[i]
            sbbox = self.selector.select_bbox_edge(pos, rpos)
            if sbbox == 1:
                self.fill_subcells_mi1(pos, dds)
                for mi1 in range(self.s1):
                    mm_s0._set_coarse(mi1)
                IF UseUncompressed == 1:
                    mm_s0._compress(mm_s)
                return
            else:
                self.recursive_morton_mask(level, pos, dds, mi1)
        ELSE:
            self.recursive_morton_mask(level, pos, dds, mi1)
        # Set coarse morton indices in order
        IF BoolType == 'Bool':
            self.set_coarse_bool(mm_s0, mm_g0)
            self.set_refined_list(mm_s0, mm_g0)
            self.set_refined_bool(mm_s0, mm_g0)
        ELSE:
            self.set_coarse_list(mm_s0, mm_g0)
            self.set_refined_list(mm_s0, mm_g0)
        IF GhostsAfter == 1:
            self.add_ghost_zones(mm_s0, mm_g0)
        # Print things
        if 0:
            mm_s0.print_info("Selector: ")
            mm_g0.print_info("Ghost   : ")
        # Compress
        IF UseUncompressed == 1:
            mm_s0._compress(mm_s)
            mm_g0._compress(mm_g)

    def masks_to_files(self, BoolArrayCollection mm_s, BoolArrayCollection mm_g):
        IF UseCythonBitmasks == 1:
            cdef FileBitmasks mm_d = self.bitmap.bitmasks
        ELSE:
            cdef BoolArrayCollection mm_d
        cdef np.int32_t ifile
        cdef np.ndarray[np.uint8_t, ndim=1] file_mask_p
        cdef np.ndarray[np.uint8_t, ndim=1] file_mask_g
        file_mask_p = np.zeros(self.nfiles, dtype="uint8")
        file_mask_g = np.zeros(self.nfiles, dtype="uint8")
        # Compare with mask of particles
        for ifile in range(self.nfiles):
            # Only continue if the file is not already selected
            if file_mask_p[ifile] == 0:
                IF UseCythonBitmasks == 1:
                    if mm_d._intersects(ifile, mm_s):
                        file_mask_p[ifile] = 1
                        file_mask_g[ifile] = 0 # No intersection
                    elif mm_d._intersects(ifile, mm_g):
                        file_mask_g[ifile] = 1
                ELSE:
                    mm_d = self.bitmap.bitmasks[ifile]
                    if mm_d._intersects(mm_s):
                        file_mask_p[ifile] = 1
                        file_mask_g[ifile] = 0 # No intersection
                    elif mm_d._intersects(mm_g):
                        file_mask_g[ifile] = 1
        cdef np.ndarray[np.int32_t, ndim=1] file_idx_p
        cdef np.ndarray[np.int32_t, ndim=1] file_idx_g
        file_idx_p = np.where(file_mask_p)[0].astype('int32')
        file_idx_g = np.where(file_mask_g)[0].astype('int32')
        return file_idx_p, file_idx_g


    def find_files(self,
                   np.ndarray[np.uint8_t, ndim=1] file_mask_p,
                   np.ndarray[np.uint8_t, ndim=1] file_mask_g):
        cdef int i
        cdef np.int32_t level = 0
        cdef np.uint64_t mi1
        mi1 = ~(<np.uint64_t>0)
        cdef np.float64_t pos[3]
        cdef np.float64_t dds[3]
        for i in range(3):
            pos[i] = self.DLE[i]
            dds[i] = self.DRE[i] - self.DLE[i]
        # Fill with input
        for i in range(self.nfiles):
            self.file_mask_p[i] = file_mask_p[i]
            self.file_mask_g[i] = file_mask_g[i]
        # Recurse
        self.recursive_morton_files(level, pos, dds, mi1)
        # Fill with results 
        for i in range(self.nfiles):
            file_mask_p[i] = self.file_mask_p[i]
            if file_mask_p[i]:
                file_mask_g[i] = 0
            else:
                file_mask_g[i] = self.file_mask_g[i]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef bint is_refined(self, np.uint64_t mi1):
        return self.bitmap.collisions._isref(mi1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef bint is_refined_files(self, np.uint64_t mi1):
        cdef int i
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection fmask
        if self.bitmap.collisions._isref(mi1):
            # Don't refine if files all selected already
            for i in range(self.nfiles):
                if self.file_mask_p[i] == 0:
                    IF UseCythonBitmasks == 1:
                        if self.bitmap.bitmasks._isref(i, mi1) == 1:
                            return 1
                    ELSE:
                        fmask = <BoolArrayCollection>self.bitmap.bitmasks[i]
                        if fmask._isref(mi1) == 1:
                            return 1
            return 0
        else:
            return 0

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void add_coarse(self, np.uint64_t mi1, int bbox = 2):
        cdef bint flag_ref = self.is_refined(mi1)
        IF BoolType == 'Bool':
            self.coarse_select_bool[mi1] = 1
        ELSE:
            self.coarse_select_list._set(mi1)
        # Neighbors
        IF GhostsAfter == 0:
            IF RefinedGhosts == 0:
                if (self.ngz > 0): 
                    IF OnlyGhostsAtEdges == 1:
                        if (bbox == 2):
                            self.add_neighbors_coarse(mi1)
                    ELSE:
                        self.add_neighbors_coarse(mi1)
            ELSE:
                if (self.ngz > 0) and (flag_ref == 0):
                    IF OnlyGhostsAtEdges == 1:
                        if (bbox == 2):
                            self.add_neighbors_coarse(mi1)
                    ELSE:
                        self.add_neighbors_coarse(mi1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void set_files_coarse(self, np.uint64_t mi1):
        cdef int i
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection fmask
        cdef bint flag_ref = self.is_refined(mi1)
        # Flag files at coarse level
        if flag_ref == 0:
            for i in range(self.nfiles):
                if self.file_mask_p[i] == 0:
                    IF UseCythonBitmasks == 1:
                        if self.bitmap.bitmasks._get_coarse(i, mi1) == 1:
                            self.file_mask_p[i] = 1
                    ELSE:
                        fmask = self.bitmap.bitmasks[i]
                        if fmask._get_coarse(mi1) == 1:
                            self.file_mask_p[i] = 1
        # Neighbors
        IF RefinedGhosts == 0:
            if (self.ngz > 0):
                self.set_files_neighbors_coarse(mi1)
        ELSE:
            if (flag_ref == 0) and (self.ngz > 0):
                self.set_files_neighbors_coarse(mi1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void add_refined(self, np.uint64_t mi1, np.uint64_t mi2, int bbox = 2):
        IF BoolType == 'Bool':
            self.refined_select_bool[mi2] = 1
        ELSE:
            self.refined_select_list._set(mi1, mi2)
        # Neighbors
        IF GhostsAfter == 0:
            IF RefinedGhosts == 1:
                if (self.ngz > 0):
                    IF OnlyGhostsAtEdges == 1:
                        if (bbox == 2):
                            self.add_neighbors_refined(mi1, mi2)
                    ELSE:
                        self.add_neighbors_refined(mi1, mi2)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void set_files_refined(self, np.uint64_t mi1, np.uint64_t mi2):
        cdef int i
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection fmask
        # Flag files
        for i in range(self.nfiles):
            if self.file_mask_p[i] == 0:
                IF UseCythonBitmasks == 1:
                    if self.bitmap.bitmasks._get(i, mi1, mi2):
                        self.file_mask_p[i] = 1
                ELSE:
                    fmask = self.bitmap.bitmasks[i]
                    if fmask._get(mi1, mi2) == 1:
                        self.file_mask_p[i] = 1
        # Neighbors
        IF RefinedGhosts == 1:
            if (self.ngz > 0):
                self.set_files_neighbors_refined(mi1, mi2)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void add_neighbors_coarse(self, np.uint64_t mi1):
        cdef int m
        cdef np.uint32_t ntot
        cdef np.uint64_t mi1_n
        ntot = morton_neighbors_coarse(mi1, self.max_index1, 
                                       self.periodicity,
                                       self.ngz, self.neighbors,
                                       self.ind1_n, self.neighbor_list1)
        for m in range(ntot):
            mi1_n = self.neighbor_list1[m]
            IF BoolType == 'Bool':
                self.coarse_ghosts_bool[mi1_n] = 1
            ELSE:
                self.coarse_ghosts_list._set(mi1_n)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void set_files_neighbors_coarse(self, np.uint64_t mi1):
        cdef int i, m
        cdef np.uint32_t ntot
        cdef np.uint64_t mi1_n
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection fmask
        ntot = morton_neighbors_coarse(mi1, self.max_index1, 
                                       self.periodicity,
                                       self.ngz, self.neighbors,
                                       self.ind1_n, self.neighbor_list1)
        for m in range(ntot):
            mi1_n = self.neighbor_list1[m]
            for i in range(self.nfiles):
                if self.file_mask_g[i] == 0:
                    IF UseCythonBitmasks == 1:
                        if self.bitmap.bitmasks._get_coarse(i, mi1_n):
                            self.file_mask_g[i] = 1
                    ELSE:
                        fmask = self.bitmap.bitmasks[i]
                        if fmask._get_coarse(mi1_n) == 1:
                            self.file_mask_g[i] = 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void add_neighbors_refined(self, np.uint64_t mi1, np.uint64_t mi2):
        cdef int m
        cdef np.uint32_t ntot
        cdef np.uint64_t mi1_n, mi2_n
        ntot = morton_neighbors_refined(mi1, mi2,
                                        self.max_index1, self.max_index2,
                                        self.periodicity, self.ngz,
                                        self.neighbors, self.ind1_n, self.ind2_n,
                                        self.neighbor_list1, self.neighbor_list2)
        for m in range(ntot):
            mi1_n = self.neighbor_list1[m]
            mi2_n = self.neighbor_list2[m]
            IF BoolType == 'Bool':
                self.coarse_ghosts_bool[mi1_n] = 1
                IF RefinedExternalGhosts == 1:
                    if mi1_n == mi1:
                        self.refined_ghosts_bool[mi2_n] = 1 
                    else:
                        self.refined_ghosts_list._set(mi1_n, mi2_n)
                ELSE:
                    if mi1_n == mi1:
                        self.refined_ghosts_bool[mi2_n] = 1 
                    elif self.is_refined(mi1_n) == 1: 
                        self.refined_ghosts_list._set(mi1_n, mi2_n)
            ELSE:
                self.coarse_ghosts_list._set(mi1_n)
                IF RefinedExternalGhosts == 1:
                    self.refined_ghosts_list._set(mi1_n, mi2_n)
                ELSE:
                    if self.is_refined(mi1_n) == 1:
                        self.refined_ghosts_list._set(mi1_n, mi2_n)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void set_files_neighbors_refined(self, np.uint64_t mi1, np.uint64_t mi2):
        cdef int i, m
        cdef np.uint32_t ntot
        cdef np.uint64_t mi1_n, mi2_n
        IF UseCythonBitmasks == 0:
            cdef BoolArrayCollection fmask
        ntot = morton_neighbors_refined(mi1, mi2,
                                        self.max_index1, self.max_index2,
                                        self.periodicity, self.ngz,
                                        self.neighbors, self.ind1_n, self.ind2_n,
                                        self.neighbor_list1, self.neighbor_list2)
        for m in range(ntot):
            mi1_n = self.neighbor_list1[m]
            mi2_n = self.neighbor_list2[m]
            if self.is_refined(mi1_n) == 1:
                for i in range(self.nfiles):
                    if self.file_mask_g[i] == 0:
                        IF UseCythonBitmasks == 1:
                            if self.bitmap.bitmasks._get(i, mi1_n, mi2_n) == 1:
                                self.file_mask_g[i] = 1
                        ELSE:
                            fmask = self.bitmap.bitmasks[i]
                            if fmask._get(mi1_n, mi2_n) == 1:
                                self.file_mask_g[i] = 1
            else:
                for i in range(self.nfiles):
                    if self.file_mask_g[i] == 0:
                        IF UseCythonBitmasks == 1:
                            if self.bitmap.bitmasks._get_coarse(i, mi1_n) == 1:
                                self.file_mask_g[i] = 1
                                break # If not refined, only one file should be selected
                        ELSE:
                            fmask = self.bitmap.bitmasks[i]
                            if fmask._get_coarse(mi1_n) == 1:
                                self.file_mask_g[i] = 1
                                break # If not refined, only one file should be selected

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void set_coarse_list(self, BoolArrayColl mm_s, BoolArrayColl mm_g):
        IF UseUncompressed == 1:
            self.coarse_select_list._fill_bool(mm_s)
        ELSE:
            self.coarse_select_list._fill_ewah(mm_s)
        IF GhostsAfter == 0:
            IF UseUncompressed == 1:
                self.coarse_ghosts_list._fill_bool(mm_g)
            ELSE:
                self.coarse_ghosts_list._fill_ewah(mm_g)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void set_refined_list(self, BoolArrayColl mm_s, BoolArrayColl mm_g):
        IF BoolType != 'Bool':
            IF UseUncompressed == 1:
                self.refined_select_list._fill_bool(mm_s)
            ELSE:
                self.refined_select_list._fill_ewah(mm_s)
        IF GhostsAfter == 0:
            IF UseUncompressed == 1:
                self.refined_ghosts_list._fill_bool(mm_g)
            ELSE:
                self.refined_ghosts_list._fill_ewah(mm_g)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void set_coarse_bool(self, BoolArrayColl mm_s, BoolArrayColl mm_g):
        cdef np.uint64_t mi1
        IF UseUncompressedView == 1:
            mm_s._set_coarse_array(self.coarse_select_bool)
            self.coarse_select_bool[:] = 0
        ELSE:
            mm_s._set_coarse_array_ptr(self.coarse_select_bool)
            for mi1 in range(self.s1):
                self.coarse_select_bool[mi1] = 0
        IF GhostsAfter == 0:
            IF UseUncompressedView == 1:
                mm_g._set_coarse_array(self.coarse_ghosts_bool)
                self.coarse_ghosts_bool[:] = 0
            ELSE:
                mm_g._set_coarse_array_ptr(self.coarse_ghosts_bool)
                for mi1 in range(self.s1):
                    self.coarse_ghosts_bool[mi1] = 0

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void set_refined_bool(self, BoolArrayColl mm_s, BoolArrayColl mm_g):
        mm_s._append(self.select_ewah)
        IF GhostsAfter == 0:
            mm_g._append(self.ghosts_ewah)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    @cython.initializedcheck(False)
    cdef void push_refined_bool(self, np.uint64_t mi1):
        IF UseUncompressedView == 1:
            self.select_ewah._set_refined_array(mi1, self.refined_select_bool)
            self.refined_select_bool[:] = 0
        ELSE:
            cdef np.uint64_t mi2
            self.select_ewah._set_refined_array_ptr(mi1, self.refined_select_bool)
            for mi2 in range(self.s2):
                self.refined_select_bool[mi2] = 0
        IF GhostsAfter == 0:
            IF UseUncompressedView == 1:
                self.ghosts_ewah._set_refined_array(mi1, self.refined_ghosts_bool)
                self.refined_ghosts_bool[:] = 0
            ELSE:
                self.ghosts_ewah._set_refined_array_ptr(mi1, self.refined_ghosts_bool)
                for mi2 in range(self.s2):
                    self.refined_ghosts_bool[mi2] = 0

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void add_ghost_zones(self, BoolArrayColl mm_s, BoolArrayColl mm_g):
        cdef np.uint64_t mi1, mi2, mi1_n, mi2_n
        # Get ghost zones, unordered
        for mi1 in range(self.s1):
            if mm_s._get_coarse(mi1):
                IF RefinedGhosts == 1:
                    if self.is_refined(mi1):
                        for mi2 in range(self.s2):
                            if mm_s._get(mi1, mi2):
                                self.add_neighbors_refined(mi1, mi2)
                        IF BoolType == 'Bool':
                            # self.push_refined_bool(mi1)
                            IF UseUncompressedView == 1:
                                self.ghosts_ewah._set_refined_array(mi1, self.refined_ghosts_bool)
                                self.refined_ghosts_bool[:] = 0
                            ELSE:
                                self.ghosts_ewah._set_refined_array_ptr(mi1, self.refined_ghosts_bool)
                                for mi2 in range(self.s2):
                                    self.refined_ghosts_bool[mi2] = 0
                    else:
                        self.add_neighbors_coarse(mi1)
                ELSE:
                    self.add_neighbors_coarse(mi1)
        # Add ghost zones to bool array in order
        IF BoolType == 'Bool':
            IF UseUncompressedView == 1:
                mm_g._set_coarse_array(self.coarse_ghosts_bool)
                self.coarse_ghosts_bool[:] = 0
            ELSE:
                mm_g._set_coarse_array_ptr(self.coarse_ghosts_bool)
                for mi1 in range(self.s1):
                    self.coarse_ghosts_bool[mi1] = 0
            # print("Before refined list: {: 6d}".format(mm_g._count_refined()))
            IF UseUncompressed == 1:
                self.refined_ghosts_list._fill_bool(mm_g)
            ELSE:
                self.refined_ghosts_list._fill_ewah(mm_g)
            # print("Before refined bool: {: 6d}".format(mm_g._count_refined()))
            # print("Bool to be appended: {: 6d}".format(self.ghosts_ewah._count_refined()))
            mm_g._append(self.ghosts_ewah)
            # print("After             :  {: 6d}".format(mm_g._count_refined()))
        ELSE:
            IF UseUncompressed == 1:
                self.coarse_ghosts_list._fill_bool(mm_g)
                self.refined_ghosts_list._fill_bool(mm_g)
            ELSE:
                self.coarse_ghosts_list._fill_ewah(mm_g)
                self.refined_ghosts_list._fill_ewah(mm_g)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void fill_subcells_mi1(self, np.float64_t pos[3], np.float64_t dds[3]):
        cdef int i, j, k
        cdef np.uint64_t mi
        cdef np.uint64_t ind1[3]
        cdef np.uint64_t indexgap[3]
        for i in range(3):
            ind1[i] = <np.uint64_t>((pos[i] - self.DLE[i])/self.bitmap.dds_mi1[i])
            indexgap[i] = <np.uint64_t>(dds[i]/self.bitmap.dds_mi1[i])
        for i in range(indexgap[0]):
            for j in range(indexgap[1]):
                for k in range(indexgap[2]):
                    mi = encode_morton_64bit(ind1[0]+i, ind1[1]+j, ind1[2]+k)
                    self.add_coarse(mi, 1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void fill_subcells_mi2(self, np.float64_t pos[3], np.float64_t dds[3]):
        cdef int i, j, k
        cdef np.uint64_t mi1, mi2
        cdef np.uint64_t ind1[3]
        cdef np.uint64_t ind2[3]
        cdef np.uint64_t indexgap[3]
        for i in range(3):
            ind1[i] = <np.uint64_t>((pos[i] - self.DLE[i])/self.bitmap.dds_mi1[i])
            ind2[i] = <np.uint64_t>((pos[i] - (self.DLE[i]+self.bitmap.dds_mi1[i]*ind1[i]))/self.bitmap.dds_mi2[i])
            indexgap[i] = <np.uint64_t>(dds[i]/self.bitmap.dds_mi2[i])
        mi1 = encode_morton_64bit(ind1[0], ind1[1], ind1[2])
        for i in range(indexgap[0]):
            for j in range(indexgap[1]):
                for k in range(indexgap[2]):
                    mi2 = encode_morton_64bit(ind2[0]+i, ind2[1]+j, ind2[2]+k)
                    self.add_refined(mi1, mi2, 1)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void recursive_morton_mask(self, np.int32_t level, np.float64_t pos[3], 
                                    np.float64_t dds[3], np.uint64_t mi1):
        cdef np.uint64_t mi2
        cdef np.float64_t npos[3]
        cdef np.float64_t rpos[3]
        cdef np.float64_t ndds[3]
        cdef np.uint64_t nlevel
        cdef np.float64_t DLE[3]
        cdef np.uint64_t ind1[3]
        cdef np.uint64_t ind2[3]
        cdef int i, j, k, m, sbbox
        for i in range(3):
            ndds[i] = dds[i]/2
        nlevel = level + 1
        # Clean up
        IF BoolType == 'Vector':
            self.coarse_select_list._prune()
            self.coarse_ghosts_list._prune()
            self.refined_select_list._prune()
            self.refined_ghosts_list._prune()
        # Loop over octs
        for i in range(2):
            npos[0] = pos[0] + i*ndds[0]
            rpos[0] = npos[0] + ndds[0]
            for j in range(2):
                npos[1] = pos[1] + j*ndds[1]
                rpos[1] = npos[1] + ndds[1]
                for k in range(2):
                    npos[2] = pos[2] + k*ndds[2]
                    rpos[2] = npos[2] + ndds[2]
                    # Only recurse into selected cells
                    IF DetectEdges == 1:
                        sbbox = self.selector.select_bbox_edge(npos, rpos)
                    ELSE:
                        sbbox = self.selector.select_bbox(npos, rpos)
                    if sbbox == 0: continue
                    IF DetectEdges == 0:
                        sbbox = 2
                    if nlevel < self.order1:
                        IF FillChildCellsCoarse == 1:
                            if sbbox == 1:
                                self.fill_subcells_mi1(npos, ndds)
                            else:
                                self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                        ELSE:
                            self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                    elif nlevel == self.order1:
                        mi1 = bounded_morton_dds(npos[0], npos[1], npos[2], self.DLE, ndds)
                        IF OnlyRefineEdges == 1:
                            if sbbox == 2: # an edge cell
                                if self.is_refined(mi1) == 1:
                                    self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                        ELSE:
                            if self.is_refined(mi1) == 1:
                                self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                        self.add_coarse(mi1, sbbox)
                        IF BoolType == 'Bool':
                            self.push_refined_bool(mi1)
                    elif nlevel < (self.order1 + self.order2):
                        IF FillChildCellsRefined == 1:
                            if sbbox == 1:
                                self.fill_subcells_mi2(npos, ndds)
                            else:
                                self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                        ELSE:
                            self.recursive_morton_mask(nlevel, npos, ndds, mi1)
                    elif nlevel == (self.order1 + self.order2):
                        decode_morton_64bit(mi1,ind1)
                        for m in range(3):
                            DLE[m] = self.DLE[m] + ndds[m]*ind1[m]*self.max_index2
                        mi2 = bounded_morton_dds(npos[0], npos[1], npos[2], DLE, ndds)
                        self.add_refined(mi1,mi2,sbbox)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void recursive_morton_files(self, np.int32_t level, np.float64_t pos[3], 
                                     np.float64_t dds[3], np.uint64_t mi1):
        cdef np.uint64_t mi2
        cdef np.float64_t npos[3]
        cdef np.float64_t rpos[3]
        cdef np.float64_t ndds[3]
        cdef np.uint64_t nlevel
        cdef np.float64_t DLE[3]
        cdef np.uint64_t ind1[3]
        cdef np.uint64_t ind2[3]
        cdef int i, j, k, m
        for i in range(3):
            ndds[i] = dds[i]/2
        nlevel = level + 1
        # Loop over octs
        for i in range(2):
            npos[0] = pos[0] + i*ndds[0]
            rpos[0] = npos[0] + ndds[0]
            for j in range(2):
                npos[1] = pos[1] + j*ndds[1]
                rpos[1] = npos[1] + ndds[1]
                for k in range(2):
                    npos[2] = pos[2] + k*ndds[2]
                    rpos[2] = npos[2] + ndds[2]
                    # Only recurse into selected cells
                    if not self.selector.select_bbox(npos, rpos): continue
                    if nlevel < self.order1:
                        self.recursive_morton_files(nlevel, npos, ndds, mi1)
                    elif nlevel == self.order1:
                        mi1 = bounded_morton_dds(npos[0], npos[1], npos[2], self.DLE, ndds)
                        if self.is_refined_files(mi1):
                            self.recursive_morton_files(nlevel, npos, ndds, mi1)
                        self.set_files_coarse(mi1)
                    elif nlevel < (self.order1 + self.order2):
                        self.recursive_morton_files(nlevel, npos, ndds, mi1)
                    elif nlevel == (self.order1 + self.order2):
                        decode_morton_64bit(mi1,ind1)
                        for m in range(3):
                            DLE[m] = self.DLE[m] + ndds[m]*ind1[m]*self.max_index2
                        mi2 = bounded_morton_dds(npos[0], npos[1], npos[2], DLE, ndds)
                        self.set_files_refined(mi1,mi2)

cdef class ParticleBitmapOctreeContainer(SparseOctreeContainer):
    cdef Oct** oct_list
    cdef public int max_level
    cdef public int n_ref
    cdef int loaded # Loaded with load_octree?
    def __init__(self, domain_dimensions, domain_left_edge, domain_right_edge,
                 int num_root, over_refine = 1):
        super(ParticleBitmapOctreeContainer, self).__init__(
            domain_dimensions, domain_left_edge, domain_right_edge,
            over_refine)
        self.loaded = 0
        self.fill_style = "o"

        # Now the overrides
        self.max_root = num_root
        self.root_nodes = <OctKey*> malloc(sizeof(OctKey) * num_root)
        for i in range(num_root):
            self.root_nodes[i].key = -1
            self.root_nodes[i].node = NULL

    def allocate_domains(self, counts = None):
        if counts is None:
            counts = [self.max_root]
        OctreeContainer.allocate_domains(self, counts)

    def finalize(self):
        #This will sort the octs in the oct list
        #so that domains appear consecutively
        #And then find the oct index/offset for
        #every domain
        cdef int max_level = 0
        self.oct_list = <Oct**> malloc(sizeof(Oct*)*self.nocts)
        cdef np.int64_t i, lpos = 0
        # Note that we now assign them in the same order they will be visited
        # by recursive visitors.
        for i in range(self.num_root):
            self.visit_assign(self.root_nodes[i].node, &lpos, 0, &max_level)
        assert(lpos == self.nocts)
        for i in range(self.nocts):
            self.oct_list[i].domain_ind = i
            # We don't assign this ... it helps with selecting later.
            #self.oct_list[i].domain = 0
            self.oct_list[i].file_ind = -1
        self.max_level = max_level

    cdef visit_assign(self, Oct *o, np.int64_t *lpos, int level, int *max_level):
        cdef int i, j, k
        self.oct_list[lpos[0]] = o
        lpos[0] += 1
        max_level[0] = imax(max_level[0], level)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_assign(o.children[cind(i,j,k)], lpos,
                                level + 1, max_level)
        return

    cdef Oct* allocate_oct(self):
        #Allocate the memory, set to NULL or -1
        #We reserve space for n_ref particles, but keep
        #track of how many are used with np initially 0
        self.nocts += 1
        cdef Oct *my_oct = <Oct*> malloc(sizeof(Oct))
        my_oct.domain = -1
        my_oct.file_ind = 0
        my_oct.domain_ind = self.nocts - 1
        my_oct.children = NULL
        return my_oct

    def __dealloc__(self):
        #Call the freemem ops on every ocy
        #of the root mesh recursively
        cdef int i
        if self.root_nodes== NULL: return
        if self.cont != NULL and self.cont.next == NULL: return
        if self.loaded == 0:
            for i in range(self.max_root):
                if self.root_nodes[i].node == NULL: continue
                self.visit_free(&self.root_nodes.node[i], 0)
            free(self.cont)
            self.cont = self.root_nodes = NULL
        free(self.oct_list)
        self.oct_list = NULL

    cdef void visit_free(self, Oct *o, int free_this):
        #Free the memory for this oct recursively
        cdef int i, j, k
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_free(o.children[cind(i,j,k)], 1)
        if o.children != NULL:
            free(o.children)
        if free_this == 1:
            free(o)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def add(self, np.ndarray[np.uint64_t, ndim=1] indices,
             np.uint64_t order1, int domain_id = -1):
        #Add this particle to the root oct
        #Then if that oct has children, add it to them recursively
        #If the child needs to be refined because of max particles, do so
        cdef Oct *cur
        cdef Oct *root = NULL
        cdef np.int64_t no = indices.shape[0], p, index
        cdef int i, level, new_root
        cdef int ind[3], last_ind[3]
        cdef np.uint64_t ind64[3]
        cdef np.uint64_t *data = <np.uint64_t *> indices.data
        # Note what we're doing here: we have decided the root will always be
        # zero, since we're in a forest of octrees, where the root_mesh node is
        # the level 0.  This means our morton indices should be made with
        # respect to that, which means we need to keep a few different arrays
        # of them.
        cdef int max_level = -1
        for i in range(3):
            last_ind[i] = -1
        for p in range(no):
            # We have morton indices, which means we choose left and right by
            # looking at (MAX_ORDER - level) & with the values 1, 2, 4.
            index = indices[p]
            decode_morton_64bit(index >> ((ORDER_MAX - order1)*3), ind64)
            if ind64[0] != last_ind[0] or \
               ind64[1] != last_ind[1] or \
               ind64[2] != last_ind[2]:
                for i in range(3):
                    last_ind[i] = ind64[i]
                self.get_root(last_ind, &root)
            if root == NULL:
                continue
            level = 0
            cur = root
            while (cur.file_ind + 1) > self.n_ref:
                if level >= ORDER_MAX: break # Just dump it here.
                level += 1
                if level > max_level: max_level = level
                for i in range(3):
                    ind[i] = (index >> ((ORDER_MAX - level)*3 + (2 - i))) & 1
                if cur.children == NULL or \
                   cur.children[cind(ind[0],ind[1],ind[2])] == NULL:
                    cur = self.refine_oct(cur, index, level)
                    self.filter_particles(cur, data, p, level)
                else:
                    cur = cur.children[cind(ind[0],ind[1],ind[2])]
            cur.file_ind += 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef Oct *refine_oct(self, Oct *o, np.uint64_t index, int level):
        #Allocate and initialize child octs
        #Attach particles to child octs
        #Remove particles from this oct entirely
        cdef int i, j, k
        cdef int ind[3]
        cdef Oct *noct
        # TODO: This does not need to be changed.
        o.children = <Oct **> malloc(sizeof(Oct *)*8)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    noct = self.allocate_oct()
                    noct.domain = o.domain
                    noct.file_ind = 0
                    o.children[cind(i,j,k)] = noct
        o.file_ind = self.n_ref + 1
        for i in range(3):
            ind[i] = (index >> ((ORDER_MAX - level)*3 + (2 - i))) & 1
        noct = o.children[cind(ind[0],ind[1],ind[2])]
        return noct

    cdef void filter_particles(self, Oct *o, np.uint64_t *data, np.int64_t p,
                               int level):
        # Now we look at the last nref particles to decide where they go.
        cdef int n = imin(p, self.n_ref)
        cdef np.uint64_t *arr = data + imax(p - self.n_ref, 0)
        # Now we figure out our prefix, which is the oct address at this level.
        # As long as we're actually in Morton order, we do not need to worry
        # about *any* of the other children of the oct.
        prefix1 = data[p] >> (ORDER_MAX - level)*3
        for i in range(n):
            prefix2 = arr[i] >> (ORDER_MAX - level)*3
            if (prefix1 == prefix2):
                o.file_ind += 1
        #print ind[0], ind[1], ind[2], o.file_ind, level
