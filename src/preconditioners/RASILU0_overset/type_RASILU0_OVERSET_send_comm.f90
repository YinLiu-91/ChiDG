module type_RASILU0_OVERSET_send_comm
#include <messenger.h>
    use mod_kinds,                  only: rk, ik
    use mod_constants,              only: NFACES, DIAG, INTERIOR
    use mod_chidg_mpi,              only: ChiDG_COMM, IRANK
    use type_ivector,               only: ivector_t
    use type_mesh,                  only: mesh_t
    use type_chidg_matrix,          only: chidg_matrix_t
    use type_mpi_request_vector,    only: mpi_request_vector_t
    use type_RASILU0_OVERSET_send_comm_dom, only: RASILU0_OVERSET_send_comm_dom_t

    use mpi_f08,                    only: MPI_ISend, MPI_INTEGER4, MPI_REQUEST, &
                                          MPI_STATUSES_IGNORE
    implicit none



    !>  A container for storing information about what gets sent to a particular 
    !!  neighbor processor.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/10/2016
    !!
    !!
    !!
    !-------------------------------------------------------------------------------------------
    type, public :: RASILU0_OVERSET_send_comm_t

        integer(ik)                                 :: proc
        type(RASILU0_OVERSET_send_comm_dom_t),  allocatable :: dom(:)   ! A description for each domain 
                                                                ! being sent. doesn't 
                                                                ! necessarily correspond to 
                                                                ! the local domains since they 
                                                                ! might not all be sent to the 
                                                                ! current processor.

        type(mpi_request_vector_t)                  :: mpi_requests

    contains

        procedure   :: init
        procedure   :: init_wait

    end type RASILU0_OVERSET_send_comm_t
    !*******************************************************************************************





contains



    !>  Initialize the data to be sent to proc.
    !!
    !!  - Determine local domains that communicate with the specified processor.
    !!  - For each domain that neighbors proc, communicate information about each overlap element
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   7/22/2016
    !!
    !!
    !!
    !-------------------------------------------------------------------------------------------
    subroutine init(self,mesh,A,proc)
        class(RASILU0_OVERSET_send_comm_t), intent(inout)   :: self
        type(mesh_t),               intent(in)      :: mesh
        type(chidg_matrix_t),       intent(in)      :: A
        integer(ik),                intent(in)      :: proc

        type(ivector_t)             :: dom_send
        integer(ik)                 :: idom, idom_send, ierr, iblk, ielem, iface, &
                                       nelem_send, ielem_send, ielem_n, iface_n, iblk_send, nblks, idiag, imat, imat_n, &
                                       idomain_g_n, ielement_g_n, ielement_l_n, itime
        integer(ik),    allocatable :: send_procs_dom(:)
        logical                     :: comm_domain, overlap_elem
        type(MPI_REQUEST)           :: request


        ! WARNING! Assuming single time-level. Not valid for Harmonic Balance
        itime = 1

        !
        ! Set send processor
        !
        self%proc = proc



        !
        ! Accumulate the domains that send to processor 'proc'
        !
        do idom = 1,mesh%ndomains()

            send_procs_dom = mesh%domain(idom)%get_send_procs_local()
            ! Check if this domain is communicating with 'proc'
            comm_domain = any(send_procs_dom == proc)
            if (comm_domain) call dom_send%push_back(idom)

        end do !idom


        !
        ! Allocate storage for element indices being sent from each dom in dom_send
        !
        allocate(self%dom(dom_send%size()), stat=ierr)
        if (ierr /= 0) call AllocationError


        !
        ! For each domain sending info to 'proc', send data from chidg_matrix.
        !
        do idom_send = 1,dom_send%size()


            idom = dom_send%at(idom_send)
            self%dom(idom_send)%idomain_g = mesh%domain(idom)%idomain_g
            self%dom(idom_send)%idomain_l = mesh%domain(idom)%idomain_l

            !
            ! Loop through element faces and find neighbors that are off-processor on 'proc' 
            ! to determine which elements to send as overlap data.
            !
            do ielem = 1,mesh%domain(idom)%nelem
                do iface = 1,NFACES

                    overlap_elem = (mesh%domain(idom)%faces(ielem,iface)%ineighbor_proc == proc)

                    if (overlap_elem) then
                        call self%dom(idom_send)%elem_send%push_back_unique(ielem)
                        exit
                    end if

                end do !iface
            end do !ielem


            nelem_send = self%dom(idom_send)%elem_send%size()
            allocate(self%dom(idom_send)%blk_send(nelem_send), stat=ierr)
            if (ierr /= 0) call AllocationError


            !
            ! Communicate the number of elements being sent to 'proc' for idomain_g
            !
            call MPI_ISend(self%dom(idom_send)%elem_send%size_, 1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
            call self%mpi_requests%push_back(request)


            !
            ! For each element in the overlap, determine which linearization blocks to send
            !
            do ielem_send = 1,self%dom(idom_send)%elem_send%size()
                ielem = self%dom(idom_send)%elem_send%at(ielem_send)


                !
                ! Communicate the indices of the element being sent
                !
                call MPI_ISend(mesh%domain(idom)%elems(ielem)%idomain_g,  1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                call self%mpi_requests%push_back(request)
                call MPI_ISend(mesh%domain(idom)%elems(ielem)%ielement_g, 1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                call self%mpi_requests%push_back(request)




                !
                ! Search for blocks to send that couple with the off-processor domain
                !
                do imat = 1,A%dom(idom)%lblks(ielem,1)%size()
                     if ( A%dom(idom)%lblks(ielem,1)%parent_proc(imat) == proc ) then
                         call self%dom(idom_send)%blk_send(ielem_send)%push_back(imat)
                     end if
                end do




                !
                ! Search neighbors to see if any of them are also overlapping blocks, 
                ! because we would need to send their linearization as well.
                !
                do iface = 1,NFACES

                    ! Get neighbor for iface
                    if ( (mesh%domain(idom)%faces(ielem,iface)%ftype          == INTERIOR) .and. &
                         (mesh%domain(idom)%faces(ielem,iface)%ineighbor_proc == IRANK   ) ) then


                        idomain_g_n  = mesh%domain(idom)%faces(ielem,iface)%ineighbor_domain_g
                        ielement_g_n = mesh%domain(idom)%faces(ielem,iface)%ineighbor_element_g
                        ielement_l_n = mesh%domain(idom)%faces(ielem,iface)%ineighbor_element_l

                        !
                        ! Find linearization of ielem wrt neighbor, ielem_n
                        !
                        imat_n = A%dom(idom)%lblks(ielem,1)%loc(idomain_g_n,ielement_g_n,itime)


                        do imat = 1,A%dom(idom)%lblks(ielement_l_n,1)%size()
                             if ( (A%dom(idom)%lblks(ielement_l_n,1)%parent_proc(imat) == proc ) .and. &
                                  (A%dom(idom)%lblks(ielement_l_n,1)%dparent_g(imat)   == self%dom(idom_send)%idomain_g) ) then
                                 call self%dom(idom_send)%blk_send(ielem_send)%push_back(imat_n)
                                 exit
                             end if
                        end do

                    end if

                end do




                !
                ! Add the block diagonal to the list to send
                !
                idiag = A%dom(idom)%lblks(ielem,1)%get_diagonal()
                call self%dom(idom_send)%blk_send(ielem_send)%push_back(idiag)




                ! Communicate the number of blocks being sent to 'proc' for element
                call MPI_ISend(self%dom(idom_send)%blk_send(ielem_send)%size_, 1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                call self%mpi_requests%push_back(request)


                ! Communicate which blocks are being send to 'proc' for element
                nblks = self%dom(idom_send)%blk_send(ielem_send)%size()
                call MPI_ISend(self%dom(idom_send)%blk_send(ielem_send)%data_(1:nblks), nblks, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                call self%mpi_requests%push_back(request)


                ! For each block send block initialization data
                do iblk_send = 1,self%dom(idom_send)%blk_send(ielem_send)%size()
                    iblk = self%dom(idom_send)%blk_send(ielem_send)%at(iblk_send)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%nterms,       1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%nfields,      1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%dparent_g_,   1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%dparent_l_,   1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%eparent_g_,   1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%eparent_l_,   1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)

                    call MPI_ISend(A%dom(idom)%lblks(ielem,1)%data_(iblk)%parent_proc_, 1, MPI_INTEGER4, proc, self%dom(idom_send)%idomain_g, ChiDG_COMM, request, ierr)
                    call self%mpi_requests%push_back(request)


                end do !iblk_send


            end do !ielem send


        end do !idom send





    end subroutine init
    !******************************************************************************************










    !>  Call MPI_Waitall for all ISend nonblocking sends that were initiated during the
    !!  initialization procedure.
    !!
    !!  This routine should be called after both 'send%init' and 'recv%init' have been executed
    !!  in the main RASILU0_OVERSET preconditioner initialization.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/08/2016
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine init_wait(self)
        class(RASILU0_OVERSET_send_comm_t),     intent(inout)   :: self

        integer(ik) :: nwait, ierr

        nwait = self%mpi_requests%size()
        if (nwait > 0) then

            ! Wall on all requests and free buffers
            call MPI_Waitall(nwait, self%mpi_requests%data(1:nwait), MPI_STATUSES_IGNORE, ierr)

            ! Clear storage vector
            call self%mpi_requests%clear()

        end if


    end subroutine init_wait
    !******************************************************************************************










end module type_RASILU0_OVERSET_send_comm
