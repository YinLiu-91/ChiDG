module type_rbf_node_vector
#include <messenger.h>
    use mod_kinds,          only: rk, ik
    use type_rbf_node,         only: rbf_node_t
    implicit none





    !>
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !----------------------------------------------------------------------------------
    type, public :: rbf_node_vector_t
        integer(ik)             :: size_        = 0
        integer(ik)             :: capacity_    = 0
        integer(ik)             :: buffer_      = 20

        type(rbf_node_t), allocatable :: data(:)

    contains

        procedure, public   :: size
        procedure, public   :: capacity

        !< Data modifiers
        procedure, public   :: push_back
        procedure, public   :: clear
        procedure, private  :: increase_capacity

        !< Data accessors
        procedure, public   :: at

    end type rbf_node_vector_t
    !**********************************************************************************



contains



    !> This function returns the number of elements stored in the container
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !-----------------------------------------------------------------------------------
    function size(self) result(res)
        class(rbf_node_vector_t),   intent(in)  :: self

        integer(ik) :: res

        res = self%size_
    end function size
    !***********************************************************************************



    !> This function returns the total capacity of the container to store elements
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !------------------------------------------------------------------------------------
    function capacity(self) result(res)
        class(rbf_node_vector_t),   intent(in)  :: self

        integer(ik) :: res

        res = self%capacity_

    end function capacity
    !************************************************************************************









    !> Store element at end of vector
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !-------------------------------------------------------------------------------------
    subroutine push_back(self,element)
        class(rbf_node_vector_t),   intent(inout)   :: self
        type(rbf_node_t),      intent(in)      :: element

        logical     :: capacity_reached
        integer(ik) :: size


        !
        ! Test if container has storage available. If not, then increase capacity
        !
        capacity_reached = (self%size() == self%capacity())
        if (capacity_reached) then
            call self%increase_capacity()
        end if


        !
        ! Add element to end of vector
        !
        size = self%size()
        self%data(size + 1) = element


        !
        ! Increment number of stored elements
        !
        self%size_ = self%size_ + 1


    end subroutine push_back
    !**************************************************************************************










    !> Clear container contents
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !---------------------------------------------------------------------------------------
    subroutine clear(self)
        class(rbf_node_vector_t),   intent(inout)   :: self

        self%size_      = 0
        self%capacity_  = 0

        if (allocated(self%data)) deallocate(self%data)

    end subroutine clear
    !****************************************************************************************










    !> Access element at index location
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !----------------------------------------------------------------------------------------
    function at(self,index) result(res)
        class(rbf_node_vector_t),   intent(in)  :: self
        integer(ik),        intent(in)  :: index

        type(rbf_node_t)   :: res
        logical         :: out_of_bounds

        !
        ! Check vector bounds
        !
        out_of_bounds = (index > self%size())
        if (out_of_bounds) then
            call chidg_signal(FATAL,'vector_t%at: out of bounds access')
        end if


        !
        ! Allocate result
        !
        res = self%data(index)

    end function at
    !*****************************************************************************************










    !> Increase the storage capacity of the vector by a buffer size predefined in the container
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine increase_capacity(self)
        class(rbf_node_vector_t),   intent(inout)   :: self

        type(rbf_node_t),  allocatable :: temp(:)
        integer(ik)             :: newsize, ierr


        !
        ! Allocate temporary vector of current size plus a buffer
        !
        if ( allocated(self%data) ) then
            newsize = ubound(self%data,1) + self%buffer_
        else
            newsize = self%buffer_
        end if

        allocate(temp(newsize),stat=ierr)
        if (ierr /= 0) call AllocationError


        !
        ! Copy any current data to temporary vector
        !
        if (allocated(self%data)) then
            temp(lbound(self%data,1):ubound(self%data,1))  =  self%data
        end if


        !
        ! Move alloc to move data back to self%data and deallocate temp
        !
        call move_alloc(FROM=temp,TO=self%data)


        !
        ! Reset capacity info
        !
        self%capacity_ = newsize


    end subroutine increase_capacity
    !********************************************************************************************
















end module type_rbf_node_vector
