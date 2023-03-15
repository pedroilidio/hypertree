# cython: boundscheck=False
from sklearn.tree._criterion cimport RegressionCriterion, Criterion
from libc.stdlib cimport malloc, calloc, free, realloc
from libc.string cimport memset
import numpy as np
cimport numpy as cnp
from ._axis_criterion cimport AxisCriterion, AxisClassificationCriterion

np.import_array()


class InvalidAxisError(ValueError):
    def __str__(self):
        return "'axis' parameter can only be 0 or 1."


cdef class BipartiteCriterion:
    """Abstract base class."""

    cdef int init(
        self,
        const DTYPE_t[:, ::1] X_rows,
        const DTYPE_t[:, ::1] X_cols,
        const DOUBLE_t[:, :] y,
        DOUBLE_t[:] row_weights,
        DOUBLE_t[:] col_weights,
        double weighted_n_rows,
        double weighted_n_cols,
        const SIZE_t[:] row_indices,
        const SIZE_t[:] col_indices,
        SIZE_t[2] start,
        SIZE_t[2] end,
    ) nogil except -1:
        return -1

    cdef void node_value(self, double* dest) nogil:
        pass

    cdef double node_impurity(self) nogil:
        pass

    cdef void children_impurity(
            self,
            double* impurity_left,
            double* impurity_right,
            SIZE_t axis,
    ) nogil:
        pass

    cdef double impurity_improvement(
        self,
        double impurity_parent,
        double impurity_left,
        double impurity_right,
        SIZE_t axis,
    ) nogil:
        """The final value to express the split quality. 
        """
    

# TODO: global in the name
cdef class RegressionCriterionGSO(BipartiteCriterion):
    def __reduce__(self):
        return (
            type(self),
            (self.criterion_rows, self.criterion_cols),
            self.__getstate__(),
        )

    def __getstate__(self):
        return {}

    def __cinit__(
        self,
        RegressionCriterion criterion_rows,
        RegressionCriterion criterion_cols,
    ):
        # Default values
        self.sq_sum_total = 0.0

        self.start[0] = 0
        self.start[1] = 0
        self.end[0] = 0
        self.end[1] = 0

        self.weighted_n_node_samples = 0.0
        self.weighted_n_node_rows = 0.0
        self.weighted_n_node_cols = 0.0

    def __init__(
        self,
        RegressionCriterion criterion_rows,
        RegressionCriterion criterion_cols,
    ):
        # Objects must be set here, to ensure they are fully initialised
        self.criterion_rows = criterion_rows
        self.criterion_cols = criterion_cols

        # Only single interaction label supported
        self.n_outputs_rows = self.criterion_rows.n_outputs
        self.n_outputs_cols = self.criterion_cols.n_outputs
        self.n_outputs = self.n_outputs_rows + self.n_outputs_cols

        if (self.n_outputs_rows != 1) or (self.n_outputs_cols != 1):
            raise ValueError(
                "Both rows and columns criteria must have n_outputs == 1. "
                f"Received {self.n_outputs_rows} and "
                f"{self.n_outputs_cols}, respectively."
            )

        self.n_rows = criterion_rows.n_samples
        self.n_cols = criterion_cols.n_samples

        # Because n_outputs == 1
        self.sum_total = np.empty(1, dtype=np.float64)
        self.y_row_sums = np.empty((self.n_rows, 1), dtype=np.float64)
        self.y_col_sums = np.empty((self.n_cols, 1), dtype=np.float64)

    cdef int init(
        self,
        const DTYPE_t[:, ::1] X_rows,
        const DTYPE_t[:, ::1] X_cols,
        const DOUBLE_t[:, :] y,
        DOUBLE_t[:] row_weights,
        DOUBLE_t[:] col_weights,
        double weighted_n_rows,
        double weighted_n_cols,
        const SIZE_t[:] row_indices,
        const SIZE_t[:] col_indices,
        SIZE_t[2] start,
        SIZE_t[2] end,
    ) nogil except -1:
        """This function adapts RegressionCriterion.init to 2D data."""
        cdef:
            SIZE_t i, j, p, q
            DOUBLE_t wi, wj, y_ij, w_y_ij
            DOUBLE_t sum_total
            double sq_sum_total
            bint is_first_row

            # Just to use y_row_sums[i] instead of y_row_sums[i, 0]
            DOUBLE_t* y_row_sums = &self.y_row_sums[0, 0]
            DOUBLE_t* y_col_sums = &self.y_col_sums[0, 0]

            SIZE_t start_row = start[0]
            SIZE_t start_col = start[1]
            SIZE_t end_row = end[0]
            SIZE_t end_col = end[1]

        # Initialize fields
        self.X_rows = X_rows
        self.X_cols = X_cols
        self.y = y
        self.row_weights = row_weights
        self.col_weights = col_weights
        self.weighted_n_rows = weighted_n_rows
        self.weighted_n_cols = weighted_n_cols
        self.weighted_n_samples = weighted_n_rows * weighted_n_cols
        self.row_indices = row_indices
        self.col_indices = col_indices

        self.start[0] = start_row
        self.start[1] = start_col
        self.end[0] = end_row
        self.end[1] = end_col

        self.n_node_rows = end_row - start_row
        self.n_node_cols = end_col - start_col

        if self.row_weights is None:
            self.weighted_n_node_rows = <double> self.n_node_rows
        else:  # Will be computed ahead
            self.weighted_n_node_rows = 0.0

        if self.col_weights is None:
            self.weighted_n_node_cols = <double> self.n_node_cols
        else:  # Will be computed ahead
            self.weighted_n_node_cols = 0.0

        # memset(&self.sum_total[0], 0, self.n_outputs * sizeof(double))
        sum_total = 0.0
        sq_sum_total = 0.0
        wi = wj = 1.0
        is_first_row = True

        # Compute sums along both y axes. Row and column sums will be used as y
        # proxies, being served as y to each child criterion.
        for p in range(start_row, end_row):
            i = row_indices[p]
            y_row_sums[i] = 0.0

            if row_weights is not None:
                wi = row_weights[i]
                self.weighted_n_node_rows += wi

            for q in range(start_col, end_col):
                j = col_indices[q]
                if is_first_row:
                    y_col_sums[j] = 0.0

                if col_weights is not None:
                    wj = col_weights[j]
                    if is_first_row:
                        self.weighted_n_node_cols += wj

                y_ij = y[i, j]
                w_y_ij = wi * wj  * y_ij

                y_row_sums[i] += wj * y_ij
                y_col_sums[j] += wi * y_ij

                sum_total += w_y_ij
                sq_sum_total += w_y_ij * y_ij

            if is_first_row:
                is_first_row = False

        self.sq_sum_total = sq_sum_total
        self.sum_total[0] = sum_total

        # Will be used by the BipartiteSplitter to set the Tree object
        self.weighted_n_node_samples = (
            self.weighted_n_node_rows * self.weighted_n_node_cols
        )

        self._init_child_criterion(
            criterion=self.criterion_rows,
            y=self.y_row_sums,
            sample_weight=self.row_weights,
            sample_indices=self.row_indices,
            start=self.start[0],
            end=self.end[0],
            n_node_samples=self.n_node_rows,  # XXX
            weighted_n_samples=self.weighted_n_rows,
            weighted_n_node_samples=self.weighted_n_node_rows,
        )
        self._init_child_criterion(
            criterion=self.criterion_cols,
            y=self.y_col_sums,
            sample_weight=self.col_weights,
            sample_indices=self.col_indices,
            start=self.start[1],
            end=self.end[1],
            n_node_samples=self.n_node_cols,  # XXX
            weighted_n_samples=self.weighted_n_cols,
            weighted_n_node_samples=self.weighted_n_node_cols,
        )

        return 0

    cdef inline int _init_child_criterion(
            self,
            RegressionCriterion criterion,
            const DOUBLE_t[:, ::1] y,
            DOUBLE_t[:] sample_weight,
            const SIZE_t[:] sample_indices,
            SIZE_t start,
            SIZE_t end,
            SIZE_t n_node_samples,
            double weighted_n_samples,
            double weighted_n_node_samples,
    ) nogil except -1:
        """Substitutes splitter.node_reset() setting child splitter on 2D data.
        """
        criterion.y = y
        criterion.sample_weight = sample_weight
        criterion.sample_indices = sample_indices
        criterion.start = start
        criterion.end = end
        criterion.n_node_samples = n_node_samples
        criterion.weighted_n_samples = weighted_n_samples
        criterion.weighted_n_node_samples = weighted_n_node_samples

        # Common for both children:
        criterion.sum_total[0] = self.sum_total[0]
        criterion.sq_sum_total = self.sq_sum_total
        criterion.reset()

        return 0

    cdef void node_value(self, double* dest) nogil:
        """Compute the node value of sample_indices[start:end] into dest."""
        # self.n_outputs is always 1
        dest[0] = self.sum_total[0] / self.weighted_n_node_samples

    cdef double impurity_improvement(
        self,
        double impurity_parent,
        double impurity_left,
        double impurity_right,
        SIZE_t axis,  # Needs axis because of weighted_n_left/weighted_n_right.
    ) nogil:
        # Fetch improvement according to the criterion on 'axis'.
        cdef double imp = (<RegressionCriterion> self._get_criterion(axis)) \
            .impurity_improvement(
                impurity_parent,
                impurity_left,
                impurity_right,
            )
        if axis == 0:
            return imp * self.weighted_n_node_cols / self.weighted_n_cols
        elif axis == 1:
            return imp * self.weighted_n_node_rows / self.weighted_n_rows

    cdef void* _get_criterion(self, SIZE_t axis) nogil except NULL:
        if axis == 0:
            return <void*> self.criterion_rows
        elif axis == 1:
            return <void*> self.criterion_cols
        else:
            with gil:
                raise InvalidAxisError


cdef class SquaredErrorGSO(RegressionCriterionGSO):

    cdef double node_impurity(self) nogil:
        """Evaluate the impurity of the current node.

        Evaluate the MSE criterion as impurity of the current node,
        i.e. the impurity of sample_indices[start:end]. The smaller the impurity the
        better.
        """
        # self.n_outputs == 1
        return (
            self.sq_sum_total / self.weighted_n_node_samples
            - (self.sum_total[0] / self.weighted_n_node_samples) ** 2.0
        )

    cdef void children_impurity(
        self,
        double* impurity_left,
        double* impurity_right,
        SIZE_t axis,
    ) nogil:
        """Evaluate the impurity in children nodes.

        i.e. the impurity of the left child (sample_indices[start:pos]) and the
        impurity the right child (sample_indices[pos:end]).

        It is done here because sq_sum_* of children criterion is set
        differently, as they receive axis sums as y.
        """
        cdef:
            DOUBLE_t y_ij
            const DOUBLE_t[:, :] y = self.y

            double sq_sum_left = 0.0
            double sq_sum_right

            SIZE_t i, j, q, p
            DOUBLE_t wi = 1.0, wj = 1.0

            const SIZE_t[:] row_indices = self.row_indices
            const SIZE_t[:] col_indices = self.col_indices
            const DOUBLE_t[:] row_weights = self.row_weights
            const DOUBLE_t[:] col_weights = self.col_weights

            double sum_left
            double sum_right
            double weighted_n_left
            double weighted_n_right

            SIZE_t start[2]
            SIZE_t end[2]

            void* criterion = self._get_criterion(axis)

        end[0], end[1] = self.end[0], self.end[1]
        start[0], start[1] = self.start[0], self.start[1]

        # Note that n_outputs is always 1
        if axis == 0:
            weighted_n_node_other = self.weighted_n_node_cols
        elif axis == 1:
            weighted_n_node_other = self.weighted_n_node_rows

        sum_left = (<RegressionCriterion> criterion).sum_left[0]
        sum_right = (<RegressionCriterion> criterion).sum_right[0]
        weighted_n_left = (<Criterion> criterion).weighted_n_left
        weighted_n_right = (<Criterion> criterion).weighted_n_right

        # TODO: changing axis crit weight to sum of column weights would
        # eliminate these lines
        weighted_n_left *= weighted_n_node_other
        weighted_n_right *= weighted_n_node_other

        end[axis] = (<Criterion> criterion).pos

        for p in range(start[0], end[0]):
            i = row_indices[p]
            if row_weights is not None:
                wi = row_weights[i]

            for q in range(start[1], end[1]):
                j = col_indices[q]
                if col_weights is not None:
                    wj = col_weights[j]

                y_ij = y[i, j]
                sq_sum_left += wi * wj * y_ij * y_ij

        sq_sum_right = self.sq_sum_total - sq_sum_left

        impurity_left[0] = (
            (sq_sum_left - (sum_left * sum_left) / weighted_n_left)
            / weighted_n_left
        )

        impurity_right[0] = (
            (sq_sum_right - (sum_right * sum_right) / weighted_n_right)
            / weighted_n_right
        )


# TODO: changing axis crit weight to sum of column weights would benefit
cdef class FriedmanGSO(SquaredErrorGSO):
    cdef double impurity_improvement(
        self,
        double impurity_parent,
        double impurity_left,
        double impurity_right,
        SIZE_t axis,  # Needs axis because of weighted_n_left/weighted_n_right.
    ) nogil:
        # Fetch improvement according to the criterion on 'axis'.
        cdef double imp = (<RegressionCriterion> self._get_criterion(axis)) \
            .impurity_improvement(
                impurity_parent,
                impurity_left,
                impurity_right,
            )
        if axis == 0:
            return imp / self.weighted_n_node_cols
        elif axis == 1:
            return imp / self.weighted_n_node_rows


cdef class GMO(BipartiteCriterion):
    """Applies Predictive Bi-Clustering Trees method.

    See [Pliakos _et al._, 2018](https://doi.org/10.1007/s10994-018-5700-x).
    """
    def __reduce__(self):
        return (
            type(self),
            (self.criterion_rows, self.criterion_cols),
            self.__getstate__(),
        )

    def __getstate__(self):
        return {}

    def __cinit__(
        self,
        AxisCriterion criterion_rows,
        AxisCriterion criterion_cols,
    ):
        # Default values
        self.sq_sum_total = 0.0

        self.start[0] = 0
        self.start[1] = 0
        self.end[0] = 0
        self.end[1] = 0

        self.weighted_n_node_samples = 0.0
        self.weighted_n_node_rows = 0.0
        self.weighted_n_node_cols = 0.0

        self.sum_total = np.zeros(self.n_outputs, dtype=np.float64)

    def __init__(
        self,
        AxisCriterion criterion_rows,
        AxisCriterion criterion_cols,
    ):
        # Objects must be set here, to ensure they are fully initialised
        self.criterion_rows = criterion_rows
        self.criterion_cols = criterion_cols

        self.n_rows = self.criterion_rows.n_samples
        self.n_cols = self.criterion_cols.n_samples
        self.n_outputs_rows = self.criterion_rows.n_outputs
        self.n_outputs_cols = self.criterion_cols.n_outputs

        # FIXME: should not validate arguments here.
        if isinstance(criterion_rows, AxisClassificationCriterion):
            if not isinstance(criterion_cols, AxisClassificationCriterion):
                raise TypeError(
                    "None or both axes criteria must be "
                    "AxisClassificationCriterion."
                )
            self.max_n_classes = (
                (<AxisClassificationCriterion>criterion_cols).max_n_classes
            )
        else:
            self.max_n_classes = 1

        self.n_outputs = self.n_outputs_rows + self.n_outputs_cols

    cdef int init(
        self,
        const DTYPE_t[:, ::1] X_rows,
        const DTYPE_t[:, ::1] X_cols,
        const DOUBLE_t[:, :] y,
        DOUBLE_t[:] row_weights,
        DOUBLE_t[:] col_weights,
        double weighted_n_rows,
        double weighted_n_cols,
        const SIZE_t[:] row_indices,
        const SIZE_t[:] col_indices,
        SIZE_t[2] start,
        SIZE_t[2] end,
    ) nogil except -1:
        """This function adapts RegressionCriterion.init to 2D data."""

        # Initialize fields
        self.X_rows = X_rows
        self.X_cols = X_cols
        self.y = y
        self.row_weights = row_weights
        self.col_weights = col_weights
        self.weighted_n_rows = weighted_n_rows
        self.weighted_n_cols = weighted_n_cols
        self.weighted_n_samples = weighted_n_rows * weighted_n_cols
        self.row_indices = row_indices
        self.col_indices = col_indices

        self.start[0], self.start[1] = start[0], start[1]
        self.end[0], self.end[1] = end[0], end[1]

        cdef SIZE_t n_node_rows = end[0] - start[0]
        cdef SIZE_t n_node_cols = end[1] - start[1]

        self.criterion_rows.axis_init(
            y=self.y,
            sample_weight=self.row_weights,
            col_weights=self.col_weights,
            weighted_n_samples=self.weighted_n_rows,
            weighted_n_cols=self.weighted_n_cols,
            sample_indices=self.row_indices,
            col_indices=self.col_indices,
            start=self.start[0],
            end=self.end[0],
            start_col=self.start[1],
            end_col=self.end[1],
        )
        self.criterion_cols.axis_init(
            y=self.y.T,
            sample_weight=self.col_weights,
            col_weights=self.row_weights,
            weighted_n_samples=self.weighted_n_cols,
            weighted_n_cols=self.weighted_n_rows,
            sample_indices=self.col_indices,
            col_indices=self.row_indices,
            start=self.start[1],
            end=self.end[1],
            start_col=self.start[0],
            end_col=self.end[0],
        )

        # Will be used by TreeBuilder as stopping criteria.
        self.weighted_n_node_rows = self.criterion_rows.weighted_n_node_samples
        self.weighted_n_node_cols = self.criterion_cols.weighted_n_node_samples

        # Will further be used by the BipartiteSplitter to set the Tree object
        self.weighted_n_node_samples = (
            self.weighted_n_node_rows * self.weighted_n_node_cols
        )

        return 0

    cdef void node_value(self, double* dest) nogil:
        """Copy the value (prototype) of node sample_indices into dest.
        """
        self.criterion_cols.node_value(dest)
        self.criterion_rows.node_value(
            dest + self.n_outputs_cols * self.max_n_classes
        )

    cdef double node_impurity(self) nogil:
        """Return the impurity of the current node.

        In scikit-learn trees it is only used at the root node.
        """
        # Should be equal among axes.
        return self.criterion_rows.node_impurity()

    cdef void children_impurity(
            self,
            double* impurity_left,
            double* impurity_right,
            SIZE_t axis,
    ) nogil:
        (<AxisCriterion> self._get_criterion(axis)).children_impurity(
            impurity_left,
            impurity_right,
        )

    cdef double impurity_improvement(
        self,
        double impurity_parent,
        double impurity_left,
        double impurity_right,
        SIZE_t axis,
    ) nogil:
        """The final value to express the split quality. 
        """
        return (<AxisCriterion> self._get_criterion(axis)).impurity_improvement(
            impurity_parent,
            impurity_left,
            impurity_right,
        )
 
    cdef void* _get_criterion(self, SIZE_t axis) nogil except NULL:
        if axis == 0:
            return <void*> self.criterion_rows
        elif axis == 1:
            return <void*> self.criterion_cols
        else:
            with gil:
                raise InvalidAxisError


cdef class GMOSA(GMO):
    def __init__(
        self,
        AxisCriterion criterion_rows,
        AxisCriterion criterion_cols,
    ):
        super().__init__(criterion_rows, criterion_cols)
        self.n_outputs = 1

    cdef void node_value(self, double* dest) nogil:
        """Copy the value (prototype) of node sample_indices into dest.
        """
        self.criterion_rows.total_node_value(dest)