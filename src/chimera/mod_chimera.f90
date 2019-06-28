!>  This module contains procedures for initializing and maintaining the Chimera
!!  interfaces.
!!
!!  detect_chimera_faces
!!  detect_chimera_donors
!!  compute_chimera_interpolators
!!  find_gq_donor
!!  clear_donor_cache
!!
!!  detect_chimera_faces, detect_chimera_donors, and compute_chimera_interpolators are probably
!!  called in src/parallel/mod_communication.f90%establish_chimera_communication.
!!
!!  @author Nathan A. Wukie
!!  @date   2/1/2016
!!
!!
!-----------------------------------------------------------------------------------
module mod_chimera
#include <messenger.h>
    use mod_kinds,              only: rk, ik
    use mod_constants,          only: NFACES, ORPHAN, CHIMERA, &
                                      XI_DIR, ETA_DIR, ZETA_DIR, &
                                      ONE, ZERO, TWO, TWO_DIM, THREE_DIM, &
                                      NO_PROC, NO_ID

    use type_point
    use type_mesh,              only: mesh_t
    use type_chimera_send,      only: chimera_send
    use type_element_info,      only: element_info_t, element_info
    use type_face_info,         only: face_info_t, face_info
    use type_ivector,           only: ivector_t
    use type_rvector,           only: rvector_t
    use type_pvector,           only: pvector_t
    use type_mvector,           only: mvector_t

    use mod_determinant,        only: det_3x3
    use mod_polynomial,         only: polynomial_val, dpolynomial_val
    use mod_periodic,           only: get_periodic_offset
    use mod_chidg_mpi,          only: IRANK, NRANK, ChiDG_COMM
    use mpi_f08,                only: MPI_BCast, MPI_Send, MPI_Recv, MPI_INTEGER4, MPI_REAL8, &
                                      MPI_LOGICAL, MPI_ANY_TAG, MPI_STATUS_IGNORE
    use ieee_arithmetic,        only: ieee_is_nan
    implicit none

    integer(ik) :: idomain_g_prev = NO_ID
    integer(ik) :: idomain_l_prev = NO_ID
    integer(ik) :: ielement_g_prev = NO_ID
    integer(ik) :: ielement_l_prev = NO_ID


    type, public, abstract:: multi_donor_rule_t

    contains
        procedure(select_donor_interface), deferred, nopass :: select_donor
    end type multi_donor_rule_t

    abstract interface 
        function select_donor_interface(mesh,donors,candidate_domains_g,candidate_domains_l,candidate_elements_g,candidate_elements_l) result(donor_index)
            import mesh_t
            import ivector_t
            import ik
            type(mesh_t),       intent(in)  :: mesh
            type(ivector_t),    intent(in)  :: donors
            type(ivector_t),    intent(in)  :: candidate_domains_g
            type(ivector_t),    intent(in)  :: candidate_domains_l
            type(ivector_t),    intent(in)  :: candidate_elements_g
            type(ivector_t),    intent(in)  :: candidate_elements_l
            integer(ik) :: donor_index
        end function
    end interface





contains


    !>  Routine for detecting Chimera faces. 
    !!
    !!  Routine flags face as a Chimera face if it has an ftype==ORPHAN, 
    !!  indicating it is not an interior face and it has not been assigned a 
    !!  boundary condition.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[inout]   mesh    Array of mesh types. One for each domain.
    !!
    !------------------------------------------------------------------------------------------
    subroutine detect_chimera_faces(mesh)
        type(mesh_t),   intent(inout)   :: mesh

        integer(ik) :: idom, ielem, iface, nnodes, ierr, ChiID
        logical     :: orphan_face = .false.
        logical     :: chimera_face = .false.

        
        !
        ! Loop through each element of each domain and look for ORPHAN face-types.
        ! If orphan is found, designate as CHIMERA 
        !
        do idom = 1,mesh%ndomains()
            do ielem = 1,mesh%domain(idom)%nelem
                do iface = 1,NFACES
                    associate( domain         => mesh%domain(idom),            &
                               domain_chimera => mesh%domain(idom)%chimera,    &
                               face           => mesh%domain(idom)%faces(ielem,iface) )

                    !
                    ! Test if the current face is unattached. 
                    ! Test also if the current face is CHIMERA in case this is being 
                    ! called as a reinitialization procedure.
                    !
                    orphan_face = ( face%ftype == ORPHAN .or. face%ftype == CHIMERA )


                    !
                    ! If orphan_face, set as Chimera face so it can search for donors in 
                    ! other domains
                    !
                    if (orphan_face) then

                        ! Set face-type to CHIMERA
                        face%ftype = CHIMERA
                        nnodes = size(face%jinv)

                        ! Set domain-local Chimera identifier. Really, just the index 
                        ! order which they were detected in, starting from 1.The n-th 
                        ! chimera face
                        face%ChiID = domain_chimera%add_receiver(domain%idomain_g,                &
                                                                 domain%idomain_l,                &
                                                                 domain%elems(ielem)%ielement_g,  &
                                                                 domain%elems(ielem)%ielement_l,  &
                                                                 iface,                           &
                                                                 nnodes)
                    end if


                    end associate
                end do ! iface
            end do ! ielem
        end do ! idom


    end subroutine detect_chimera_faces
    !****************************************************************************************






    !>  Routine for generating the data in a chimera_receiver_data instance. 
    !!  This includes donor_domain and donor_element indices.
    !!
    !!  For each Chimera face, find a donor for each quadrature node on the face, 
    !!  for a given node, initialize information about its donor.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @parma[in]  mesh    Array of mesh_t instances
    !!
    !----------------------------------------------------------------------------------------
    subroutine detect_chimera_donors(mesh)
        type(mesh_t),   intent(inout)   :: mesh

        integer(ik) :: idom, igq, ichimera_face, idonor, ierr, iproc,                           &
                       idonor_proc, iproc_loop,                                                 &
                       ndonors, neqns, nterms_s,                                                &
                       idonor_domain_g, idonor_element_g, idonor_domain_l, idonor_element_l,    &
                       idomain_g_list, idomain_l_list, ielement_g_list, ielement_l_list,        &
                       neqns_list, nterms_s_list, nterms_c_list, iproc_list, eqn_ID_list,       &
                       local_domain_g, parallel_domain_g, donor_domain_g, donor_index,          &
                       donor_ID, send_ID
        integer(ik) :: receiver_indices(6), parallel_indices(10)


        real(rk)                :: donor_metric(3,3), parallel_metric(3,3)
        real(rk), allocatable   :: donor_vols(:)
        real(rk)                :: gq_coords(3), offset(3), gq_node(3), &
                                   donor_jinv, donor_vol, local_vol, parallel_vol, parallel_jinv

        type(face_info_t)       :: receiver
        type(element_info_t)    :: donor
        real(rk)                :: donor_coord(3)
        logical                 :: new_donor     = .false.
        logical                 :: already_added = .false.
        logical                 :: donor_match   = .false.
        logical                 :: searching
        logical                 :: donor_found
        logical                 :: proc_has_donor
        logical                 :: still_need_donor
        logical                 :: local_donor, parallel_donor
        logical                 :: use_local, use_parallel, get_donor

        type(ivector_t)         :: donor_proc_indices, donor_proc_domains
        type(rvector_t)         :: donor_proc_vols


        !
        ! Loop through processes. One will process its chimera faces and try to 
        ! find processor-local donors. If it can't find on-processor donors, then 
        ! it will broadcast a search request to all other processors. All other processors
        ! receive the request and return if they have a donor element or not.
        !
        ! The processes loop through in this serial fashion until all processors have 
        ! processed their Chimera faces and have found donor elements for the quadrature 
        ! nodes.
        !
        do iproc = 0,NRANK-1


            !
            ! iproc searches for donors for it's Chimera faces
            !
            if ( iproc == IRANK ) then
                do idom = 1,mesh%ndomains()
                    call write_line('   Detecting chimera donors for domain: ', idom, delimiter='  ', ltrim=.false.)


                    !
                    ! Loop over faces and process Chimera-type faces
                    !
                    do ichimera_face = 1,mesh%domain(idom)%chimera%nreceivers()

                        !
                        ! Get location of the face receiving Chimera data
                        !
                        receiver%idomain_g  = mesh%domain(idom)%chimera%recv(ichimera_face)%idomain_g
                        receiver%idomain_l  = mesh%domain(idom)%chimera%recv(ichimera_face)%idomain_l
                        receiver%ielement_g = mesh%domain(idom)%chimera%recv(ichimera_face)%ielement_g
                        receiver%ielement_l = mesh%domain(idom)%chimera%recv(ichimera_face)%ielement_l
                        receiver%iface      = mesh%domain(idom)%chimera%recv(ichimera_face)%iface

                        call write_line('   Face ', ichimera_face,' of ',mesh%domain(idom)%chimera%nreceivers(), '      (domain,element,face) = ', receiver%idomain_g, receiver%ielement_g, receiver%iface, delimiter='  ')

                        !
                        ! Loop through quadrature nodes on Chimera face and find donors
                        !
                        do igq = 1,mesh%domain(receiver%idomain_l)%faces(receiver%ielement_l,receiver%iface)%basis_s%nnodes_face()


                            !
                            ! Get node coordinates
                            !
                            !gq_node = mesh%domain(receiver%idomain_l)%faces(receiver%ielement_l,receiver%iface)%interp_coords_def(igq,1:3)
                            gq_node = mesh%domain(receiver%idomain_l)%faces(receiver%ielement_l,receiver%iface)%interp_coords(igq,1:3)


                            !
                            ! Get offset coordinates from face for potential periodic offset.
                            !
                            offset = get_periodic_offset(mesh%domain(receiver%idomain_l)%faces(receiver%ielement_l,receiver%iface))



                            searching = .true.
                            call MPI_BCast(searching,1,MPI_LOGICAL, iproc, ChiDG_COMM, ierr)

                            ! Send gq node physical coordinates
                            call MPI_BCast(gq_node,3,MPI_REAL8, iproc, ChiDG_COMM, ierr)
                            call MPI_BCast(offset, 3,MPI_REAL8, iproc, ChiDG_COMM, ierr)

                            ! Send receiver indices
                            receiver_indices(1) = receiver%idomain_g
                            receiver_indices(2) = receiver%idomain_l
                            receiver_indices(3) = receiver%ielement_g
                            receiver_indices(4) = receiver%ielement_l
                            receiver_indices(5) = receiver%iface
                            receiver_indices(6) = receiver%dof_start
                            call MPI_BCast(receiver_indices,6,MPI_INTEGER4, iproc, ChiDG_COMM, ierr)



                            !
                            ! Call routine to find LOCAL gq donor for current node
                            !
                            call find_gq_donor(mesh,                &
                                               gq_node,             &
                                               offset,              &
                                               receiver,            &
                                               donor,               &
                                               donor_coord,         &
                                               donor_found,         &
                                               donor_volume=local_vol)

                            local_domain_g = 0
                            local_donor = .false.
                            if ( donor_found ) then
                                local_donor = .true.
                            end if



                            !
                            ! Check which processors have a valid donor
                            !
                            do idonor_proc = 0,NRANK-1
                                if (idonor_proc /= IRANK) then
                                    ! Check if a donor was found on proc idonor_proc
                                    call MPI_Recv(proc_has_donor,1,MPI_LOGICAL, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)

                                    if (proc_has_donor) then
                                        call donor_proc_indices%push_back(idonor_proc)

                                        call MPI_Recv(donor_domain_g,1,MPI_INTEGER4, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)
                                        call donor_proc_domains%push_back(donor_domain_g)

                                        call MPI_Recv(donor_vol,1,MPI_REAL8, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)
                                        call donor_proc_vols%push_back(donor_vol)
                                    end if
                                end if
                            end do !idonor_proc



                            !
                            ! If there is a parallel donor, determine which has the lowest volume
                            !
                            parallel_domain_g = 0
                            parallel_donor = .false.
                            if ( donor_proc_indices%size() > 0 ) then
                                donor_vols = donor_proc_vols%data()
                                donor_index = minloc(donor_vols,1)

                                parallel_vol = donor_vols(donor_index)
                                parallel_donor = .true.
                            end if
                            


                            !
                            ! Determine which donor to use
                            !
                            if ( local_donor .and. parallel_donor ) then
                                use_local    = (local_vol    < parallel_vol)
                                use_parallel = (parallel_vol < local_vol   )

                            else if (local_donor .and. (.not. parallel_donor)) then
                                use_local = .true.
                                use_parallel = .false.

                            else if (parallel_donor .and. (.not. local_donor)) then
                                use_local = .false.
                                use_parallel = .true.

                            else
                                call chidg_signal(FATAL,"detect_chimera_donor: no valid donor found")
                            end if




                            !
                            ! Overwrite donor data if use_parallel
                            !
                            if (use_parallel) then

                                !
                                ! Send a message to the processes that have donors to indicate if we would like to use it
                                !
                                do iproc_loop = 1,donor_proc_indices%size()

                                    idonor_proc = donor_proc_indices%at(iproc_loop)
                                    get_donor   = (iproc_loop == donor_index)
                                    call MPI_Send(get_donor,1,MPI_LOGICAL, idonor_proc, 0, ChiDG_COMM, ierr)

                                end do !idonor_proc

                                !
                                ! Receive parallel donor index from processor indicated
                                !
                                idonor_proc = donor_proc_indices%at(donor_index)
                                call MPI_Recv(parallel_indices,10,MPI_INTEGER4, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)
!                                donor%idomain_g  = parallel_indices(1)
!                                donor%idomain_l  = parallel_indices(2)
!                                donor%ielement_g = parallel_indices(3)
!                                donor%ielement_l = parallel_indices(4)
!                                donor%iproc      = parallel_indices(5)
!                                donor%eqn_ID     = parallel_indices(6)
!                                donor%nfields    = parallel_indices(7)
!                                donor%nterms_s   = parallel_indices(8)
!                                donor%nterms_c   = parallel_indices(9)
!                                donor%dof_start  = parallel_indices(10)
                                
                                donor = element_info(idomain_g  = parallel_indices(1),  &
                                                     idomain_l  = parallel_indices(2),  &
                                                     ielement_g = parallel_indices(3),  &
                                                     ielement_l = parallel_indices(4),  &
                                                     iproc      = parallel_indices(5),  &
                                                     pelem_ID   = NO_ID, &
                                                     eqn_ID     = parallel_indices(6),  &
                                                     nfields    = parallel_indices(7),  &
                                                     nterms_s   = parallel_indices(8),  &
                                                     nterms_c   = parallel_indices(9),  &
                                                     dof_start  = parallel_indices(10), &
                                                     dof_local_start = NO_ID, &
                                                     recv_comm       = NO_ID, &
                                                     recv_domain     = NO_ID, &
                                                     recv_element    = NO_ID, &
                                                     recv_dof        = NO_ID)


                                ! 1: Receive donor local coordinate
                                ! 2: Receive donor metric matrix
                                ! 3: Receive donor inverse jacobian mapping
                                call MPI_Recv(donor_coord,  3,MPI_REAL8, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)
                                call MPI_Recv(donor_metric, 9,MPI_REAL8, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)
                                call MPI_Recv(donor_jinv,   1,MPI_REAL8, idonor_proc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)



                            else if (use_local) then

                                ! Send a message to all procs with donors that we don't need them
                                get_donor = .false.
                                do iproc_loop = 1,donor_proc_indices%size()
                                    idonor_proc = donor_proc_indices%at(iproc_loop)
                                    call MPI_Send(get_donor,1,MPI_LOGICAL, idonor_proc, 0, ChiDG_COMM, ierr)
                                end do

                                donor_metric = mesh%domain(donor%idomain_l)%elems(donor%ielement_l)%metric_point(donor_coord,coordinate_frame='Undeformed',coordinate_scaling=.true.)
                                donor_jinv   = ONE/det_3x3(donor_metric)


                            else 
                                call chidg_signal(FATAL,"detect_chimera_donors: no local or parallel donor found")

                            end if


                            !
                            ! Add donor
                            !
                            donor_ID = mesh%domain(idom)%chimera%recv(ichimera_face)%add_donor(donor%idomain_g, donor%idomain_l, donor%ielement_g, donor%ielement_l, donor%iproc)
                            call mesh%domain(idom)%chimera%recv(ichimera_face)%donor(donor_ID)%set_properties(donor%nterms_c,donor%nterms_s,donor%nfields,donor%eqn_ID,donor%dof_start,donor%dof_local_start)
                            call mesh%domain(idom)%chimera%recv(ichimera_face)%donor(donor_ID)%add_node(igq,donor_coord,donor_metric,donor_jinv)


                            !
                            ! Clear working vectors
                            !
                            call donor_proc_indices%clear()
                            call donor_proc_domains%clear()
                            call donor_proc_vols%clear()

                        end do ! igq

                    end do ! iface
                end do ! idom

            searching = .false.
            call MPI_BCast(searching,1,MPI_LOGICAL, iproc, ChiDG_COMM, ierr)

            end if ! iproc == IRANK





            !
            ! Each other proc waits for donor requests from iproc and sends back donors if they are found.
            !
            if (iproc /= IRANK) then

                !
                ! Check if iproc is searching for a node 
                !
                call MPI_BCast(searching,1,MPI_LOGICAL,iproc,ChiDG_COMM,ierr)



                do while(searching)

                    !
                    ! Receive gq node physical coordinates from iproc
                    !
                    call MPI_BCast(gq_node,3,MPI_REAL8, iproc, ChiDG_COMM, ierr)
                    call MPI_BCast(offset, 3,MPI_REAL8, iproc, ChiDG_COMM, ierr)

                    
                    !
                    ! Receive receiver indices
                    !
                    call MPI_BCast(receiver_indices,6,MPI_INTEGER4, iproc, ChiDG_COMM, ierr)
                    receiver = face_info(receiver_indices(1),   &
                                         receiver_indices(2),   &
                                         receiver_indices(3),   &
                                         receiver_indices(4),   &
                                         receiver_indices(5),   &
                                         receiver_indices(6)    &
                                         )


                    !
                    ! Try to find donor
                    !
                    call find_gq_donor(mesh,                &
                                       gq_node,             &
                                       offset,              &
                                       receiver,            &
                                       donor,               &
                                       donor_coord,         &
                                       donor_found,         &
                                       donor_volume=donor_vol)

                    
                    !
                    ! Send status
                    !
                    call MPI_Send(donor_found,1,MPI_LOGICAL,iproc,0,ChiDG_COMM,ierr)

                    if (donor_found) then

                        call MPI_Send(donor%idomain_g,1,MPI_INTEGER4,iproc,0,ChiDG_COMM,ierr)
                        call MPI_Send(donor_vol,1,MPI_REAL8,iproc,0,ChiDG_COMM,ierr)

                        call MPI_Recv(still_need_donor,1,MPI_LOGICAL, iproc, MPI_ANY_TAG, ChiDG_COMM, MPI_STATUS_IGNORE, ierr)

                        if (still_need_donor) then

                            ! Add donor to the chimera send collection
                            send_ID = mesh%domain(donor%idomain_l)%chimera%find_send(donor%idomain_g, donor%ielement_g)
                            if (send_ID == NO_ID) then
                                send_ID = mesh%domain(donor%idomain_l)%chimera%new_send()
                                mesh%domain(donor%idomain_l)%chimera%send(send_ID) = chimera_send(donor%idomain_g, donor%idomain_l, donor%ielement_g, donor%ielement_l)
                            end if
                            call mesh%domain(donor%idomain_l)%chimera%send(send_ID)%send_procs%push_back_unique(iproc)


                            ! 1: Send donor indices
                            ! 2: Send donor-local coordinate for the quadrature node
                            parallel_indices(1)  = donor%idomain_g
                            parallel_indices(2)  = donor%idomain_l
                            parallel_indices(3)  = donor%ielement_g
                            parallel_indices(4)  = donor%ielement_l
                            parallel_indices(5)  = donor%iproc
                            parallel_indices(6)  = donor%eqn_ID
                            parallel_indices(7)  = donor%nfields
                            parallel_indices(8)  = donor%nterms_s
                            parallel_indices(9)  = donor%nterms_c
                            parallel_indices(10) = donor%dof_start

                            call MPI_Send(parallel_indices,10,MPI_INTEGER4,iproc,0,ChiDG_COMM,ierr)
                            call MPI_Send(donor_coord,3,MPI_REAL8,iproc,0,ChiDG_COMM,ierr)


                            ! Compute metric terms for the point in the donor element
                            parallel_metric = mesh%domain(donor%idomain_l)%elems(donor%ielement_l)%metric_point(donor_coord, coordinate_frame='Undeformed', coordinate_scaling=.true.)
                            parallel_jinv   = ONE/det_3x3(parallel_metric)

                            ! Communicate metric and jacobian 
                            call MPI_Send(parallel_metric, 9, MPI_REAL8, iproc, 0, ChiDG_COMM, ierr)
                            call MPI_Send(parallel_jinv,   1, MPI_REAL8, iproc, 0, ChiDG_COMM, ierr)

                        end if

                    end if


                    !
                    ! Check if iproc is searching for another node
                    !
                    call MPI_BCast(searching,1,MPI_LOGICAL,iproc,ChiDG_COMM,ierr)


                end do ! while searching

            end if ! iproc /= IRANK

        end do ! iproc

        
        ! Clear cache of last detected overset donor.
        call clear_donor_cache()


    end subroutine detect_chimera_donors
    !*************************************************************************************











    !> Compute the matrices that interpolate solution data from a donor element expansion
    !! to the receiver nodes.
    !!
    !! These matrices get stored in:
    !!      mesh(idom)%chimera%recv(ChiID)%donor_interpolator
    !!      mesh(idom)%chimera%recv(ChiID)%donor_interpolator_grad1
    !!      mesh(idom)%chimera%recv(ChiID)%donor_interpolator_grad2
    !!      mesh(idom)%chimera%recv(ChiID)%donor_interpolator_grad3
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !-------------------------------------------------------------------------------
    subroutine compute_chimera_interpolators(mesh)
        type(mesh_t),   intent(inout)   :: mesh

        integer(ik)     :: idom, ChiID, idonor, ierr, ipt, iterm,   &
                           donor_idomain_g, donor_idomain_l,        &
                           donor_ielement_g, donor_ielement_l,      &
                           npts, donor_nterms_s, spacedim
        real(rk)        :: node(3), jinv, ddxi, ddeta, ddzeta

        real(rk), allocatable, dimension(:,:)   ::  &
            interpolator, interpolator_grad1, interpolator_grad2, interpolator_grad3, metric

        

        !
        ! Loop over all domains
        !
        do idom = 1,mesh%ndomains()

            !
            ! Loop over each chimera face
            !
            do ChiID = 1,mesh%domain(idom)%chimera%nreceivers()

                
                !
                ! For each donor, compute an interpolation matrix
                !
                do idonor = 1,mesh%domain(idom)%chimera%recv(ChiID)%ndonors()

                    donor_idomain_g  = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%idomain_g
                    donor_idomain_l  = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%idomain_l
                    donor_ielement_g = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%ielement_g
                    donor_ielement_l = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%ielement_l
                    donor_nterms_s   = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%nterms_s

                    !
                    ! Get number of GQ points this donor is responsible for
                    !
                    npts   = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%nnodes()

                    !
                    ! Allocate interpolator matrix
                    !
                    if (allocated(interpolator)) deallocate(interpolator,       &
                                                            interpolator_grad1, &
                                                            interpolator_grad2, &
                                                            interpolator_grad3)
                    allocate(interpolator(      npts,donor_nterms_s), &
                             interpolator_grad1(npts,donor_nterms_s), &
                             interpolator_grad2(npts,donor_nterms_s), &
                             interpolator_grad3(npts,donor_nterms_s), stat=ierr)
                    if (ierr /= 0) call AllocationError

                    !
                    ! Compute values of modal polynomials at the donor nodes
                    !
                    do iterm = 1,donor_nterms_s
                        do ipt = 1,npts

                            node = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%coords(ipt,:)

                            !
                            ! Compute value interpolator
                            !
                            spacedim = 3
                            interpolator(ipt,iterm) = polynomial_val(spacedim,donor_nterms_s,iterm,node)

                            
                            !
                            ! Compute gradient interpolators, grad1, grad2, grad3
                            !
                            ddxi   = dpolynomial_val(spacedim,donor_nterms_s,iterm,node,XI_DIR  )
                            ddeta  = dpolynomial_val(spacedim,donor_nterms_s,iterm,node,ETA_DIR )
                            ddzeta = dpolynomial_val(spacedim,donor_nterms_s,iterm,node,ZETA_DIR)

                            ! Get metrics for element mapping
                            metric = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%metric(:,:,ipt)
                            jinv   = mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%jinv(ipt)

                            ! Compute cartesian derivative interpolator for gq node
                            interpolator_grad1(ipt,iterm) = metric(1,1) * ddxi   + &
                                                            metric(2,1) * ddeta  + &
                                                            metric(3,1) * ddzeta 
                            interpolator_grad2(ipt,iterm) = metric(1,2) * ddxi   + &
                                                            metric(2,2) * ddeta  + &
                                                            metric(3,2) * ddzeta 
                            interpolator_grad3(ipt,iterm) = metric(1,3) * ddxi   + &
                                                            metric(2,3) * ddeta  + &
                                                            metric(3,3) * ddzeta 

                        end do ! ipt
                    end do ! iterm

                    !
                    ! Store interpolators
                    !
                    mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%value = interpolator
                    mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%grad1 = interpolator_grad1
                    mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%grad2 = interpolator_grad2
                    mesh%domain(idom)%chimera%recv(ChiID)%donor(idonor)%grad3 = interpolator_grad3


                end do  ! idonor



            end do  ! ChiID
        end do  ! idom


        
        !
        ! Communicate mesh
        !
        call mesh%comm_send()
        call mesh%comm_recv()   ! also calls mesh%assemble_chimera_data to construct data on complete exterior node set.
        call mesh%comm_wait()



    end subroutine compute_chimera_interpolators
    !********************************************************************************











    !>  Find the domain and element indices for an element that contains a given 
    !!  quadrature node and can donate interpolated solution values to the receiver face.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]      mesh                Array of mesh_t instances
    !!  @param[in]      gq_node             GQ point that needs to find a donor
    !!  @param[in]      receiver_face       Location of face containing the gq_node
    !!  @param[inout]   donor_element       Location of the donor element that was found
    !!  @param[inout]   donor_coordinate    Point defining the location of the GQ point in the donor coordinate system
    !!  @param[inout]   donor_volume        Volume of the donor element that can be used to select between donors if 
    !!                                      multiple are available.
    !!
    !-------------------------------------------------------------------------------------
    subroutine find_gq_donor(mesh,gq_node,offset,receiver_face,donor_element,donor_coordinate,donor_found,donor_volume,multi_donor_rule)
        type(mesh_t),               intent(in)              :: mesh
        real(rk),                   intent(in)              :: gq_node(3)
        real(rk),                   intent(in)              :: offset(3)
        type(face_info_t),          intent(in)              :: receiver_face
        type(element_info_t),       intent(inout)           :: donor_element
        real(rk),                   intent(inout)           :: donor_coordinate(3)
        logical,                    intent(inout)           :: donor_found
        real(rk),                   intent(inout), optional :: donor_volume
        class(multi_donor_rule_t),  intent(in),    optional :: multi_donor_rule

        integer(ik)                 :: idom, ielem, inewton, idomain_g, idomain_l,      &
                                       ielement_g, ielement_l, icandidate, ncandidates, &
                                       idonor, ndonors, donor_index, donor_domain_l, donor_element_l

        real(rk), allocatable   :: xcenter(:), ycenter(:), zcenter(:), dist(:), donor_vols(:)
        real(rk)                :: xgq, ygq, zgq, dx, dy, dz, xi, eta, zeta, xn, yn, zn,    &
                                   xmin, xmax, ymin, ymax, zmin, zmax,                      &
                                   xcenter_recv, ycenter_recv, zcenter_recv

        real(rk)                :: donor_comp(3), recv_comp(3), search1, search2, search3, &
                                   offset1, offset2, offset3
        type(ivector_t)         :: candidate_domains_g, candidate_domains_l, &
                                   candidate_elements_g, candidate_elements_l
        type(ivector_t)         :: donors
        type(rvector_t)         :: donors_xi, donors_eta, donors_zeta

        logical                 :: contained  = .false.
        logical                 :: receiver   = .false.
        logical                 :: node_found = .false.
        logical                 :: node_self  = .false.


        xgq = gq_node(1)
        ygq = gq_node(2)
        zgq = gq_node(3)

        offset1 = offset(1)
        offset2 = offset(2)
        offset3 = offset(3)

        search1 = xgq + offset1
        search2 = ygq + offset2
        search3 = zgq + offset3


        ! Try previous donor, since it is relatively likely the previous donor
        ! for a quadrature node set will satisfy the next node. Consider
        ! abutting boundaries, all nodes are satisfied by the same donor.
        !---------------------------------------------------------------------
        ndonors = 0
        if (idomain_g_prev /= NO_ID) then
            idomain_g  = idomain_g_prev
            idomain_l  = idomain_l_prev
            ielement_g = ielement_g_prev
            ielement_l = ielement_l_prev
            call candidate_domains_g%push_back(idomain_g)
            call candidate_domains_l%push_back(idomain_l)
            call candidate_elements_g%push_back(ielement_g)
            call candidate_elements_l%push_back(ielement_l)
            ncandidates = 1

            ! Try to find donor (xi,eta,zeta) coordinates for receiver (xgq,ygq,zgq)
            donor_comp = mesh%domain(idomain_l)%elems(ielement_l)%computational_point([search1,search2,search3])    ! Newton's method routine

            ! Node is not nan
            node_found = (any(ieee_is_nan(donor_comp)) .eqv. .false.) 

            ! Node is not self: could be periodic, so same element is okay, but we don't want the same node
            if ( (idomain_g == receiver_face%idomain_g) .and. (ielement_g == receiver_face%ielement_g) ) then
                recv_comp  = mesh%domain(idomain_l)%elems(ielement_l)%computational_point([xgq, ygq, zgq])
                node_self = (abs(sum(recv_comp - donor_comp)) < 1.e-3_rk)
            else
                node_self = .false.
            end if

            ! Add donor if donor_comp is valid
            if ( node_found .and. (.not. node_self)) then
                ndonors = ndonors + 1
                call donors%push_back(1)
                call donors_xi%push_back(  donor_comp(1))
                call donors_eta%push_back( donor_comp(2))
                call donors_zeta%push_back(donor_comp(3))
            end if
        end if
        !---------------------------------------------------------------------



        ! If the previous donor didn't work, then we will go through a global
        ! search again.
        if (ndonors == 0) then

            !
            ! Loop through LOCAL domains and search for potential donor candidates
            !
            ncandidates = 0
            call candidate_domains_g%clear()
            call candidate_domains_l%clear()
            call candidate_elements_g%clear()
            call candidate_elements_l%clear()
            do idom = 1,mesh%ndomains()
                idomain_g = mesh%domain(idom)%idomain_g
                idomain_l = mesh%domain(idom)%idomain_l


                !
                ! Loop through elements in the current domain
                !
                do ielem = 1,mesh%domain(idom)%nelem
                    ielement_g = mesh%domain(idom)%elems(ielem)%ielement_g
                    ielement_l = mesh%domain(idom)%elems(ielem)%ielement_l

                    !
                    ! Get bounding coordinates for the current element
                    !
                    xmin = minval(mesh%domain(idom)%elems(ielem)%node_coords(:,1))
                    xmax = maxval(mesh%domain(idom)%elems(ielem)%node_coords(:,1))
                    ymin = minval(mesh%domain(idom)%elems(ielem)%node_coords(:,2))
                    ymax = maxval(mesh%domain(idom)%elems(ielem)%node_coords(:,2))
                    zmin = minval(mesh%domain(idom)%elems(ielem)%node_coords(:,3))
                    zmax = maxval(mesh%domain(idom)%elems(ielem)%node_coords(:,3))

                    !
                    ! Grow bounding box by 10%. Use delta x,y,z instead of scaling xmin etc. in case xmin is 0
                    !
                    dx = abs(xmax - xmin)  
                    dy = abs(ymax - ymin)
                    dz = abs(zmax - zmin)

                    xmin = xmin - 0.1*dx
                    xmax = xmax + 0.1*dx
                    ymin = ymin - 0.1*dy
                    ymax = ymax + 0.1*dy
                    zmin = (zmin-0.001) - 0.1*dz    ! This is to help 2D
                    zmax = (zmax+0.001) + 0.1*dz    ! This is to help 2D

                    !
                    ! Test if gq_node is contained within the bounding coordinates
                    !
                    contained = ( (xmin < search1) .and. (search1 < xmax ) .and. &
                                  (ymin < search2) .and. (search2 < ymax ) .and. &
                                  (zmin < search3) .and. (search3 < zmax ) )


                    ! If the node was within the bounding coordinates, flag the element as a potential donor
                    if (contained) then
                        call candidate_domains_g%push_back(idomain_g)
                        call candidate_domains_l%push_back(idomain_l)
                        call candidate_elements_g%push_back(ielement_g)
                        call candidate_elements_l%push_back(ielement_l)
                        ncandidates = ncandidates + 1
                    end if

                end do ! ielem

            end do ! idom


            !
            ! Test gq_node physical coordinates on candidate element volume to try and map to donor local coordinates
            !
            ndonors = 0
            do icandidate = 1,ncandidates
                idomain_g  = candidate_domains_g%at(icandidate)
                idomain_l  = candidate_domains_l%at(icandidate)
                ielement_g = candidate_elements_g%at(icandidate)
                ielement_l = candidate_elements_l%at(icandidate)

                ! Try to find donor (xi,eta,zeta) coordinates for receiver (xgq,ygq,zgq)
                donor_comp = mesh%domain(idomain_l)%elems(ielement_l)%computational_point([search1,search2,search3])    ! Newton's method routine

                ! Node is not nan
                node_found = (any(ieee_is_nan(donor_comp)) .eqv. .false.) 

                ! Node is not self: could be periodic, so same element is okay, but we don't want the same node
                if ( (idomain_g == receiver_face%idomain_g) .and. (ielement_g == receiver_face%ielement_g) ) then
                    recv_comp  = mesh%domain(idomain_l)%elems(ielement_l)%computational_point([xgq, ygq, zgq])
                    node_self = (abs(sum(recv_comp - donor_comp)) < 1.e-3_rk)
                else
                    node_self = .false.
                end if

                ! Add donor if donor_comp is valid
                if ( node_found .and. (.not. node_self)) then
                    ndonors = ndonors + 1
                    call donors%push_back(icandidate)
                    call donors_xi%push_back(  donor_comp(1))
                    call donors_eta%push_back( donor_comp(2))
                    call donors_zeta%push_back(donor_comp(3))
                    !exit
                end if

            end do ! icandidate


        end if !ndonors == 0, from check of previous donor element.

        

        ! Sanity check on donors and set donor_element location
        if (ndonors == 0) then
            donor_element%idomain_g  = 0
            donor_element%idomain_l  = 0
            donor_element%ielement_g = 0
            donor_element%ielement_l = 0
            donor_element%iproc      = NO_PROC

            donor_found = .false.

        elseif (ndonors == 1) then

            idonor = donors%at(1)   ! donor index from candidates

            donor_domain_l  = candidate_domains_l%at(idonor)
            donor_element_l = candidate_elements_l%at(idonor)

            donor_element = element_info(idomain_g       = mesh%domain(donor_domain_l)%elems(donor_element_l)%idomain_g, &
                                         idomain_l       = mesh%domain(donor_domain_l)%elems(donor_element_l)%idomain_l, &
                                         ielement_g      = mesh%domain(donor_domain_l)%elems(donor_element_l)%ielement_g, &
                                         ielement_l      = mesh%domain(donor_domain_l)%elems(donor_element_l)%ielement_l, &
                                         iproc           = IRANK, &
                                         pelem_ID        = NO_ID, &
                                         eqn_ID          = mesh%domain(donor_domain_l)%elems(donor_element_l)%eqn_ID, &
                                         nfields         = mesh%domain(donor_domain_l)%elems(donor_element_l)%neqns, &
                                         nterms_s        = mesh%domain(donor_domain_l)%elems(donor_element_l)%nterms_s, &
                                         nterms_c        = mesh%domain(donor_domain_l)%elems(donor_element_l)%nterms_c, &
                                         dof_start       = mesh%domain(donor_domain_l)%elems(donor_element_l)%dof_start, &
                                         dof_local_start = mesh%domain(donor_domain_l)%elems(donor_element_l)%dof_local_start, &
                                         recv_comm       = NO_ID, &
                                         recv_domain     = NO_ID, &
                                         recv_element    = NO_ID, &
                                         recv_dof        = NO_ID)


            xi   = donors_xi%at(1)
            eta  = donors_eta%at(1)
            zeta = donors_zeta%at(1)
            donor_coordinate = [xi,eta,zeta]
            donor_found = .true.
            if (present(donor_volume)) donor_volume = mesh%domain(donor_element%idomain_l)%elems(donor_element%ielement_l)%vol


        elseif (ndonors > 1) then


            ! Handle multiple potential donors: Choose donor with minimum volume - should be best resolved
            if (allocated(donor_vols) ) deallocate(donor_vols)
            allocate(donor_vols(donors%size()))
            
    
            ! If provided a rule use that, if not select by lowest volume
            if (present(multi_donor_rule)) then
                donor_index = multi_donor_rule%select_donor(mesh,donors,candidate_domains_g,candidate_domains_l,candidate_elements_g,candidate_elements_l)
            else
                ! Get index of domain with minimum volume
                do idonor = 1,donors%size()
                    donor_vols(idonor) = mesh%domain(candidate_domains_l%at(donors%at(idonor)))%elems(candidate_elements_l%at(donors%at(idonor)))%vol
                end do 
                donor_index = minloc(donor_vols,1)
            end if

            idonor = donors%at(donor_index)

            donor_domain_l  = candidate_domains_l%at(idonor)
            donor_element_l = candidate_elements_l%at(idonor)

            donor_element = element_info(idomain_g       = mesh%domain(donor_domain_l)%elems(donor_element_l)%idomain_g, &
                                         idomain_l       = mesh%domain(donor_domain_l)%elems(donor_element_l)%idomain_l, &
                                         ielement_g      = mesh%domain(donor_domain_l)%elems(donor_element_l)%ielement_g, &
                                         ielement_l      = mesh%domain(donor_domain_l)%elems(donor_element_l)%ielement_l, &
                                         iproc           = IRANK, &
                                         pelem_ID        = NO_ID, &
                                         eqn_ID          = mesh%domain(donor_domain_l)%elems(donor_element_l)%eqn_ID, &
                                         nfields         = mesh%domain(donor_domain_l)%elems(donor_element_l)%neqns, &
                                         nterms_s        = mesh%domain(donor_domain_l)%elems(donor_element_l)%nterms_s, &
                                         nterms_c        = mesh%domain(donor_domain_l)%elems(donor_element_l)%nterms_c, &
                                         dof_start       = mesh%domain(donor_domain_l)%elems(donor_element_l)%dof_start, &
                                         dof_local_start = mesh%domain(donor_domain_l)%elems(donor_element_l)%dof_local_start, &
                                         recv_comm       = NO_ID, &
                                         recv_domain     = NO_ID, &
                                         recv_element    = NO_ID, &
                                         recv_dof        = NO_ID)



            ! Set donor coordinate and volume if present
            xi   = donors_xi%at(donor_index)
            eta  = donors_eta%at(donor_index)
            zeta = donors_zeta%at(donor_index)
            donor_coordinate = [xi,eta,zeta]
            donor_found = .true.
            if (present(donor_volume)) donor_volume = mesh%domain(donor_element%idomain_l)%elems(donor_element%ielement_l)%vol


        else
            call chidg_signal(FATAL,"find_gq_donor: invalid number of donors")
        end if



        ! Store donor as previous donor, only if one was found. Don't want to
        ! set to zero!
        if (ndonors > 0) then
            idomain_g_prev = donor_element%idomain_g
            idomain_l_prev = donor_element%idomain_l
            ielement_g_prev = donor_element%ielement_g
            ielement_l_prev = donor_element%ielement_l
        end if


    end subroutine find_gq_donor
    !******************************************************************************





    !>  Try to find an element from the list of mesh%parallel_elements(:) that have 
    !!  already been identified and initialialized that contains a given quadrature 
    !!  node and can donate interpolated solution values to the receiver face. 
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/24/2018
    !!
    !!  @param[in]      mesh                mesh_t instance.
    !!  @param[in]      gq_node             (c1,c2,c3) point that needs to find a donor.
    !!  @param[in]      offset              (dc1, dc2, dc3) offset to the search location.
    !!  @param[in]      receiver_face       Location of face containing the gq_node
    !!  @param[inout]   donor_element       Location of the donor element that was found
    !!  @param[inout]   donor_coordinate    Point defining the location of the GQ point in the donor coordinate system.
    !!  @param[inout]   donor_found         Logical, indicating if a donor element was found or not.
    !!  @param[inout]   donor_volume        Volume of the donor element that can be used to select between donors if 
    !!                                      multiple are available.
    !!
    !-------------------------------------------------------------------------------------
    subroutine find_gq_donor_parallel(mesh,gq_node,offset,receiver_face,donor_element,donor_coordinate,donor_found,donor_volume)
        type(mesh_t),               intent(in)              :: mesh
        real(rk),                   intent(in)              :: gq_node(3)
        real(rk),                   intent(in)              :: offset(3)
        type(face_info_t),          intent(in)              :: receiver_face
        type(element_info_t),       intent(inout)           :: donor_element
        real(rk),                   intent(inout)           :: donor_coordinate(3)
        logical,                    intent(inout)           :: donor_found
        real(rk),                   intent(inout), optional :: donor_volume


        integer(ik)                 :: idom, ielem, inewton, idomain_g, idomain_l,      &
                                       ielement_g, ielement_l, icandidate, idonor,      &
                                       donor_index, pelem_ID

        real(rk), allocatable   :: xcenter(:), ycenter(:), zcenter(:), dist(:), donor_vols(:)
        real(rk)                :: xgq, ygq, zgq, dx, dy, dz, xi, eta, zeta, xn, yn, zn,    &
                                   xmin, xmax, ymin, ymax, zmin, zmax,                      &
                                   xcenter_recv, ycenter_recv, zcenter_recv

        real(rk)                :: donor_comp(3), recv_comp(3), search1, search2, search3, offset1, offset2, offset3
        type(ivector_t)         :: candidate_elements
        type(ivector_t)         :: donors_pelem_ID
        type(rvector_t)         :: donors_xi, donors_eta, donors_zeta

        logical                 :: contained  = .false.
        logical                 :: receiver   = .false.
        logical                 :: node_found = .false.
        logical                 :: node_self  = .false.

        xgq = gq_node(1)
        ygq = gq_node(2)
        zgq = gq_node(3)

        offset1 = offset(1)
        offset2 = offset(2)
        offset3 = offset(3)

        search1 = xgq + offset1
        search2 = ygq + offset2
        search3 = zgq + offset3


        !
        ! Loop through PARALLEL elements and search for potential donor candidates.
        !
        do pelem_ID = 1,mesh%nparallel_elements()

            !
            ! Get bounding coordinates for the current element
            !
            xmin = minval(mesh%parallel_element(pelem_ID)%node_coords(:,1))
            xmax = maxval(mesh%parallel_element(pelem_ID)%node_coords(:,1))
            ymin = minval(mesh%parallel_element(pelem_ID)%node_coords(:,2))
            ymax = maxval(mesh%parallel_element(pelem_ID)%node_coords(:,2))
            zmin = minval(mesh%parallel_element(pelem_ID)%node_coords(:,3))
            zmax = maxval(mesh%parallel_element(pelem_ID)%node_coords(:,3))

            !
            ! Grow bounding box by 10%. Use delta x,y,z instead of scaling xmin etc. in case xmin is 0
            !
            dx = abs(xmax - xmin)  
            dy = abs(ymax - ymin)
            dz = abs(zmax - zmin)

            xmin = xmin - 0.1*dx
            xmax = xmax + 0.1*dx
            ymin = ymin - 0.1*dy
            ymax = ymax + 0.1*dy
            zmin = (zmin-0.001) - 0.1*dz    ! This is to help 2D
            zmax = (zmax+0.001) + 0.1*dz    ! This is to help 2D

            !
            ! Test if gq_node is contained within the bounding coordinates
            !
            contained = ( (xmin < search1) .and. (search1 < xmax ) .and. &
                          (ymin < search2) .and. (search2 < ymax ) .and. &
                          (zmin < search3) .and. (search3 < zmax ) )


            !
            ! If the node was within the bounding coordinates, flag the element as a potential donor
            !
            if (contained) then
                call candidate_elements%push_back(pelem_ID)
            end if


        end do ! ielem



        !
        ! Test gq_node physical coordinates on candidate element volume to try and map to donor local coordinates
        !
        do icandidate = 1,candidate_elements%size()

            pelem_ID   = candidate_elements%at(icandidate)
            idomain_g  = mesh%parallel_element(pelem_ID)%idomain_g
            ielement_g = mesh%parallel_element(pelem_ID)%ielement_g

            !
            ! Try to find donor (xi,eta,zeta) coordinates for receiver (xgq,ygq,zgq)
            !
            donor_comp = mesh%parallel_element(pelem_ID)%computational_point([search1,search2,search3])    ! Newton's method routine


            ! Node is not nan
            node_found = (any(ieee_is_nan(donor_comp)) .eqv. .false.) 

            ! Node is not self: could be periodic, so same element is okay, but we don't want the same node
            if ( (idomain_g == receiver_face%idomain_g) .and. (ielement_g == receiver_face%ielement_g) ) then
                recv_comp  = mesh%parallel_element(pelem_ID)%computational_point([xgq, ygq, zgq])
                node_self = (abs(sum(recv_comp - donor_comp)) < 1.e-3_rk)
            else
                node_self = .false.
            end if


            ! Add donor if donor_comp is valid
            if ( node_found .and. (.not. node_self)) then
                call donors_pelem_ID%push_back(pelem_ID)
                call donors_xi%push_back(  donor_comp(1))
                call donors_eta%push_back( donor_comp(2))
                call donors_zeta%push_back(donor_comp(3))
            end if

        end do ! icandidate





        !
        ! Sanity check on donors and set donor_element location
        !
        if (donors_pelem_ID%size() == 0) then
            !donor_element = element_info_t(0, 0, 0, NO_PROC, NO_ID, 0, 0, 0, 0)
            donor_element = element_info(idomain_g       = 0,       &
                                         idomain_l       = 0,       &
                                         ielement_g      = 0,       &
                                         ielement_l      = 0,       &
                                         iproc           = NO_PROC, &
                                         pelem_ID        = NO_ID,   &
                                         eqn_ID          = NO_ID,   &
                                         nfields         = 0,       &
                                         nterms_s        = 0,       &
                                         nterms_c        = 0,       &
                                         dof_start       = NO_ID,   &
                                         dof_local_start = NO_ID,   &
                                         recv_comm       = NO_ID,   &
                                         recv_domain     = NO_ID,   &
                                         recv_element    = NO_ID,   &
                                         recv_dof        = NO_ID)

            donor_found = .false.


        elseif (donors_pelem_ID%size() == 1) then
            pelem_ID = donors_pelem_ID%at(1)   ! donor index from candidates
            donor_element = element_info(idomain_g       = mesh%parallel_element(pelem_ID)%idomain_g,       &
                                         idomain_l       = mesh%parallel_element(pelem_ID)%idomain_l,       &
                                         ielement_g      = mesh%parallel_element(pelem_ID)%ielement_g,      &
                                         ielement_l      = mesh%parallel_element(pelem_ID)%ielement_l,      &
                                         iproc           = mesh%parallel_element(pelem_ID)%iproc,           &
                                         pelem_ID        = pelem_ID,                                        &
                                         eqn_ID          = mesh%parallel_element(pelem_ID)%eqn_ID,          &
                                         nfields         = mesh%parallel_element(pelem_ID)%neqns,           &
                                         nterms_s        = mesh%parallel_element(pelem_ID)%nterms_s,        &
                                         nterms_c        = mesh%parallel_element(pelem_ID)%nterms_c,        &
                                         dof_start       = mesh%parallel_element(pelem_ID)%dof_start,       &
                                         dof_local_start = mesh%parallel_element(pelem_ID)%dof_local_start, &
                                         recv_comm       = mesh%parallel_element(pelem_ID)%recv_comm,       &
                                         recv_domain     = mesh%parallel_element(pelem_ID)%recv_domain,     &
                                         recv_element    = mesh%parallel_element(pelem_ID)%recv_element,    &
                                         recv_dof        = mesh%parallel_element(pelem_ID)%recv_dof)


            xi   = donors_xi%at(1)
            eta  = donors_eta%at(1)
            zeta = donors_zeta%at(1)
            donor_coordinate = [xi,eta,zeta]
            donor_found = .true.
            if (present(donor_volume)) donor_volume = mesh%parallel_element(pelem_ID)%vol



        elseif (donors_pelem_ID%size() > 1) then
            !
            ! Handle multiple potential donors: Choose donor with minimum volume - should be best resolved
            !
            if (allocated(donor_vols) ) deallocate(donor_vols)
            allocate(donor_vols(donors_pelem_ID%size()))
            
            do idonor = 1,donors_pelem_ID%size()
                pelem_ID = donors_pelem_ID%at(idonor)
                donor_vols(idonor) = mesh%parallel_element(pelem_ID)%vol
            end do 
    

            !
            ! Get index of domain with minimum volume
            !
            donor_index = minloc(donor_vols,1)
            pelem_ID = donors_pelem_ID%at(donor_index)   ! donor index from candidates with minimum volume

!            donor_element = element_info_t(mesh%parallel_element(pelem_ID)%idomain_g,   &
!                                           mesh%parallel_element(pelem_ID)%idomain_l,   &
!                                           mesh%parallel_element(pelem_ID)%ielement_g,  &
!                                           mesh%parallel_element(pelem_ID)%ielement_l,  &
!                                           mesh%parallel_element(pelem_ID)%iproc,       &
!                                           pelem_ID,                                    &
!                                           mesh%parallel_element(pelem_ID)%eqn_ID,      &
!                                           mesh%parallel_element(pelem_ID)%neqns,       &
!                                           mesh%parallel_element(pelem_ID)%nterms_s,    &
!                                           mesh%parallel_element(pelem_ID)%nterms_c)
            donor_element = element_info(idomain_g       = mesh%parallel_element(pelem_ID)%idomain_g,       &
                                         idomain_l       = mesh%parallel_element(pelem_ID)%idomain_l,       &
                                         ielement_g      = mesh%parallel_element(pelem_ID)%ielement_g,      &
                                         ielement_l      = mesh%parallel_element(pelem_ID)%ielement_l,      &
                                         iproc           = mesh%parallel_element(pelem_ID)%iproc,           &
                                         pelem_ID        = pelem_ID,                                        &
                                         eqn_ID          = mesh%parallel_element(pelem_ID)%eqn_ID,          &
                                         nfields         = mesh%parallel_element(pelem_ID)%neqns,           &
                                         nterms_s        = mesh%parallel_element(pelem_ID)%nterms_s,        &
                                         nterms_c        = mesh%parallel_element(pelem_ID)%nterms_c,        &
                                         dof_start       = mesh%parallel_element(pelem_ID)%dof_start,       &
                                         dof_local_start = mesh%parallel_element(pelem_ID)%dof_local_start, &
                                         recv_comm       = mesh%parallel_element(pelem_ID)%recv_comm,       &
                                         recv_domain     = mesh%parallel_element(pelem_ID)%recv_domain,     &
                                         recv_element    = mesh%parallel_element(pelem_ID)%recv_element,    &
                                         recv_dof        = mesh%parallel_element(pelem_ID)%recv_dof)

            !
            ! Set donor coordinate and volume if present
            !
            xi   = donors_xi%at(donor_index)
            eta  = donors_eta%at(donor_index)
            zeta = donors_zeta%at(donor_index)
            donor_coordinate = [xi,eta,zeta]
            donor_found = .true.
            if (present(donor_volume)) donor_volume = mesh%parallel_element(pelem_ID)%vol


        else
            call chidg_signal(FATAL,"find_gq_donor_parallel: invalid number of donors")
        end if




    end subroutine find_gq_donor_parallel
    !******************************************************************************



    !>  Reset the module indices corresponding to the last detected overset donor.
    !!
    !!  This should be called when a new environment is initialized and is setup 
    !!  to be called in chidg%start_up('core').
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   12/26/2018
    !!
    !------------------------------------------------------------------------------
    subroutine clear_donor_cache()

        ! Reset previous donor element to null, so future calls (maybe in tests) don't
        ! try to access an element that might not exist.
        idomain_g_prev = NO_ID
        idomain_l_prev = NO_ID
        ielement_g_prev = NO_ID
        ielement_l_prev = NO_ID

    end subroutine clear_donor_cache
    !******************************************************************************








end module mod_chimera
