module type_domain
#include <messenger.h>
    use mod_kinds,                  only: rk,ik
    use mod_constants,              only: XI_MIN,XI_MAX,ETA_MIN,ETA_MAX,ZETA_MIN,ZETA_MAX, &
                                          ORPHAN, INTERIOR, BOUNDARY, CHIMERA, TWO_DIM, &
                                          THREE_DIM, NO_NEIGHBOR_FOUND, NEIGHBOR_FOUND, &
                                          NO_PROC, NFACES, ZERO, NO_MM_ASSIGNED,        &
                                          MAX_ELEMENTS_PER_NODE, NO_ELEMENT, NO_ID, TWO
    use mod_grid,                   only: FACE_CORNERS, NFACE_CORNERS
    use mod_chidg_mpi,              only: IRANK, NRANK, GLOBAL_MASTER
    use mpi_f08

    use type_element,               only: element_t
    use type_face,                  only: face_t
    use type_ivector,               only: ivector_t
    use type_chimera,               only: chimera_t
    use type_domain_connectivity,   only: domain_connectivity_t
    use type_element_connectivity,  only: element_connectivity_t
    implicit none
    private


    !>  Domain data type.
    !!
    !!  A domain_t contains arrays of elements and faces that define the geometry.
    !!  It also contains information about Chimera interfaces. 
    !!
    !!
    !!  For each element in a domain, there is an entry in domain%elems(:). In this
    !!  way, elements can be accessed by element index as:
    !!      domain%elems(ielem)
    !!
    !!  For each element, there are six faces. So, a face(iface) for a given element(ielem) 
    !!  can be accessed as:
    !!      domain%faces(ielem,iface)
    !!
    !!  Information on any Chimera interfaces for the domain are contains in domain%chimera
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/27/2016
    !!
    !!  @author Nathan A. Wukie
    !!  @date   4/4/2016
    !!  @note   restructure, create domain_t from previously mesh_t
    !!
    !-----------------------------------------------------------------------------------------
    type, public :: domain_t

        character(:),   allocatable     :: name

        !
        ! Integer parameters
        !
        integer(ik)                     :: idomain_g
        integer(ik)                     :: idomain_l
        integer(ik)                     :: domain_dof_start         ! Based on Fortran 1-indexing
        integer(ik)                     :: domain_dof_local_start   ! Based on Fortran 1-indexing
        integer(ik)                     :: domain_xdof_start        ! Based on Fortran 1-indexing
        integer(ik)                     :: domain_xdof_local_start  ! Based on Fortran 1-indexing

        integer(ik)                     :: nfields     = 0     ! N-equations being solved
        integer(ik)                     :: nterms_s    = 0     ! N-terms in solution expansion
        integer(ik)                     :: nelements_g = 0     ! Number of elements in the global domain
        integer(ik)                     :: nelem       = 0     ! Number of total elements
        integer(ik)                     :: ntime       = 0     ! Number of time instances
        integer(ik)                     :: mm_ID       = NO_MM_ASSIGNED
        integer(ik),    allocatable     :: procs(:)            ! A list of all processors owning a part of idomain_g
        character(:),   allocatable     :: coordinate_system   ! 'Cartesian' or 'Cylindrical'

        
        !
        ! domain data
        !
        real(rk),           allocatable :: nodes(:,:)      ! Nodes of the reference domain.                 Proc-global. (nnodes, 3-coords)
        real(rk),           allocatable :: dnodes(:,:)     ! Node displacements: node_ale = nodes + dnodes. Proc-global. (nnodes, 3-coords)
        real(rk),           allocatable :: vnodes(:,:)     ! Node velocities:                               Proc-global. (nnodes, 3-coords)
        integer(ik),        allocatable :: nodes_elems(:,:) ! Local element indices associated with each node (nnodes, MAX_ELEMENTS_PER_NODE)

        type(element_t),    allocatable :: elems(:)        ! Element storage (1:nelem)
        type(face_t),       allocatable :: faces(:,:)      ! Face storage (1:nelem,1:nfaces)
        

        ! chimera interfaces container
        type(chimera_t)                 :: chimera  


        !
        ! Initialization flags
        !
        logical   :: geomInitialized          = .false. ! Status of geometry initialization
        logical   :: solInitialized           = .false. ! Status of numerics initialization
        logical   :: local_comm_initialized   = .false. ! Status of processor-local comm init
        logical   :: global_comm_initialized  = .false. ! Status of processor-global comm init

    contains

        procedure           :: init_geom                ! geometry init for elements and faces 
        procedure           :: init_sol                 ! init data depending on solution order for elements and faces
        procedure           :: init_eqn                 ! initialize the equation set identifier on the mesh

        procedure, private  :: init_elems_geom          ! Loop through elements init geometry
        procedure, private  :: init_elems_sol           ! Loop through elements init data depending on the solution order
        procedure, private  :: init_faces_geom          ! Loop through faces init geometry
        procedure, private  :: init_faces_sol           ! Loop through faces init data depending on the solution order

        procedure           :: compute_area_weighted_h  ! Compute an area weighted version of h for each element in the domain

        procedure           :: init_comm_local          ! For faces, find proc-local neighbors, initialize face neighbor indices 
        procedure           :: init_comm_global         ! For faces, find neighbors across procs, initialize face neighbor indices
        procedure           :: find_face_owner
        procedure           :: transmit_face_info

        ! ALE
        procedure, public   :: set_displacements_velocities
        procedure           :: update_interpolations_ale

        ! Mesh-sensitivities
        procedure, public   :: compute_interpolations_dx ! Compute derivatives of loal interpolators
        procedure, public   :: release_interpolations_dx ! Compute derivatives of loal interpolators

        ! Utilities
        procedure, private  :: find_neighbor_local      ! Try to find a neighbor for a particular face on the local processor
!        procedure, private  :: find_neighbor_global     ! Try to find a neighbor for a particular face across processors
!        procedure           :: handle_neighbor_request  ! When a neighbor request from another processor comes in, 
!                                                        ! check if current processor contains neighbor


        procedure,  public  :: get_recv_procs           ! Return proc ranks receiving from (neighbor+chimera)
        procedure,  public  :: get_recv_procs_local     ! Return proc ranks receiving neighbor data from
        procedure,  public  :: get_recv_procs_chimera   ! Return proc ranks receiving chimera data from 

        procedure,  public  :: get_send_procs           ! Return proc ranks sending to (neighbor+chimera)
        procedure,  public  :: get_send_procs_local     ! Return proc ranks sending neighbor data to
        procedure,  public  :: get_send_procs_chimera   ! Return proc ranks sending chimera data to

        procedure,  public  :: get_nelements_global             ! Return number of elements in the global domain
        procedure,  public  :: get_nelements_local              ! Return number of elements in the processor-local domain
        procedure,  public  :: nelements => get_nelements_local ! Included for framework consistency

        procedure,  public  :: get_dof_start
        procedure,  public  :: get_dof_end
        procedure,  public  :: get_dof_local_start
        procedure,  public  :: get_dof_local_end

        final               :: destructor

    end type domain_t
    !*****************************************************************************************





contains






    !>  Mesh geometry initialization procedure
    !!
    !!  Sets number of terms in coordinate expansion for the entire domain
    !!  and calls sub-initialization routines for individual element and face geometry
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  idomain_l       Proc-local domain index.
    !!  @param[in]  nelements_g     Proc-global number of elements in the domain.
    !!  @param[in]  nodes           Proc-global node list.                  (nnodes, 3-coords)
    !!  @param[in]  dnodes          Proc-global node coordinate delta list. (nnodes, 3-coords)
    !!  @param[in]  connectivity    Proc-local connectivities.
    !!  @param[in]  coord_system    Coordinate system of the nodal coordinates.
    !!  
    !!  TODO: test dnodes initialization
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_geom(self,idomain_l,nelements_g,nodes,connectivity,coord_system)
        class(domain_t),                intent(inout)   :: self
        integer(ik),                    intent(in)      :: idomain_l
        integer(ik),                    intent(in)      :: nelements_g
        real(rk),                       intent(in)      :: nodes(:,:)
        type(domain_connectivity_t),    intent(in)      :: connectivity
        character(*),                   intent(in)      :: coord_system

        !
        ! Store number of terms in coordinate expansion and domain index
        !
        self%idomain_g    = connectivity%get_domain_index()
        self%idomain_l    = idomain_l
        self%nelements_g  = nelements_g


        !
        ! Initialize nodes:
        !   Reference nodes = nodes
        !   Default node coordinate deltas = zero
        !
        self%nodes  = nodes
        self%dnodes = nodes
        self%vnodes = nodes
        self%dnodes = ZERO
        self%vnodes = ZERO


        ! Allocate the storage for registering elements with nodes
        allocate(self%nodes_elems(size(nodes(:,1)), MAX_ELEMENTS_PER_NODE))
        ! Initialize so that each node has no element registered
        self%nodes_elems = NO_ELEMENT


        !
        ! Call geometry initialization for elements and faces
        !
        call self%init_elems_geom(nodes,connectivity,coord_system)
        call self%init_faces_geom()


        !
        ! Set coordinate system and confirm initialization 
        !
        self%coordinate_system = coord_system
        self%geomInitialized = .true.


    end subroutine init_geom
    !*****************************************************************************************








    !>  Initialize ALE data from node displacement data. 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/16/2017
    !!
    !!
    !!  TODO: Test
    !!
    !----------------------------------------------------------------------------------------
    subroutine set_displacements_velocities(self,dnodes,vnodes)
        class(domain_t),        intent(inout)   :: self
        real(rk),               intent(in)      :: dnodes(:,:)
        real(rk),               intent(in)      :: vnodes(:,:)

        integer(ik) :: ielem, iface

        do ielem = 1,self%nelem
            call self%elems(ielem)%set_displacements_velocities(dnodes,vnodes)
            do iface = 1,NFACES
                call self%faces(ielem,iface)%set_displacements_velocities(self%elems(ielem))
            end do !iface
        end do !ielem

    end subroutine set_displacements_velocities
    !*****************************************************************************************


    !>  Initialize ALE data from node displacement data. 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/16/2017
    !!
    !!
    !!  TODO: Test
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_interpolations_ale(self)
        class(domain_t),        intent(inout)   :: self

        integer(ik) :: ielem, iface

        do ielem = 1,self%nelem
            call self%elems(ielem)%update_interpolations_ale()
            do iface = 1,NFACES
                call self%faces(ielem,iface)%update_interpolations_ale(self%elems(ielem))
            end do !iface
        end do !ielem


    end subroutine update_interpolations_ale
    !*****************************************************************************************







    !>  Mesh numerics initialization procedure
    !!
    !!  Sets number of equations being solved, number of terms in the solution expansion and
    !!  calls sub-initialization routines for individual element and face numerics
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @author Mayank Sharma + Matteo Ugolotti
    !!  @date   11/9/2016
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_sol(self,interpolation,level,nterms_s,nfields,ntime,domain_dof_start,domain_dof_local_start,domain_xdof_start,domain_xdof_local_start)
        class(domain_t),    intent(inout)   :: self
        character(*),       intent(in)      :: interpolation
        integer(ik),        intent(in)      :: level
        integer(ik),        intent(in)      :: nterms_s
        integer(ik),        intent(in)      :: nfields
        integer(ik),        intent(in)      :: ntime
        integer(ik),        intent(in)      :: domain_dof_start
        integer(ik),        intent(in)      :: domain_dof_local_start
        integer(ik),        intent(in)      :: domain_xdof_start
        integer(ik),        intent(in)      :: domain_xdof_local_start

        ! Store number of equations and number of terms in solution expansion
        self%nfields                 = nfields
        self%nterms_s                = nterms_s
        self%ntime                   = ntime
        self%domain_dof_start        = domain_dof_start
        self%domain_dof_local_start  = domain_dof_local_start
        self%domain_xdof_start       = domain_xdof_start
        self%domain_xdof_local_start = domain_xdof_local_start

        ! Call numerics initialization for elements and faces
        call self%init_elems_sol(interpolation,level,nterms_s,nfields,ntime)
        call self%init_faces_sol()               
        call self%update_interpolations_ale()

        ! Confirm initialization
        self%solInitialized = .true.

    end subroutine init_sol
    !*****************************************************************************************








    !>  Initialize the equation set identifier on the mesh.
    !!
    !!  Sets the equation set identifier self%eqn_ID that can be used to acces
    !!  the equation_set_t object on chidg_data as chidg_data%eqnset(eqn_ID)
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/20/2017
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_eqn(self,eqn_ID)
        class(domain_t),  intent(inout)   :: self
        integer(ik),    intent(in)      :: eqn_ID

        integer(ik) :: ielem

        ! Assign all elements in the domain to the equation set identifier.
        do ielem = 1,self%nelements()
            call self%elems(ielem)%init_eqn(eqn_ID)
        end do

    end subroutine init_eqn
    !*****************************************************************************************







    !>  Mesh - element initialization procedure
    !!
    !!  Computes the number of elements based on the element mapping selected and
    !!  calls the element initialization procedure on individual elements.
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !!  @param[in]  points_g    Rank-3 matrix of coordinate points defining a block mesh
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_elems_geom(self,nodes,domain_connectivity,coord_system)
        class(domain_t),                intent(inout)   :: self
        real(rk),                       intent(in)      :: nodes(:,:)
        type(domain_connectivity_t),    intent(in)      :: domain_connectivity
        character(*),                   intent(in)      :: coord_system


        type(element_connectivity_t)    :: element_connectivity
        integer(ik)                     :: ierr, nelem, location(5), etype,             &
                                           idomain_g, ielement_g, idomain_l, ielement_l, &  
                                           inode, inode_elem, ireg
        integer(ik),    allocatable     :: connectivity(:)
        logical                         :: node_reg_failed


        ! Store total number of elements
        nelem      = domain_connectivity%get_nelements()
        self%nelem = nelem


        ! Allocate element storage
        allocate(self%elems(nelem), stat=ierr)
        if (ierr /= 0) call chidg_signal(FATAL,"mesh%init_elems_geom: Memory allocation error: init_elements")


        ! Call geometry initialization for each element
        idomain_l = self%idomain_l
        do ielement_l = 1,nelem

            element_connectivity = domain_connectivity%get_element_connectivity(ielement_l)
            connectivity = element_connectivity%get_element_nodes()
            idomain_g    = element_connectivity%get_domain_index()
            ielement_g   = element_connectivity%get_element_index()
            location     = [idomain_g, idomain_l, ielement_g, ielement_l, IRANK]
            etype        = element_connectivity%get_element_mapping()

            call self%elems(ielement_l)%init_geom(nodes,connectivity,etype,location,coord_system)


            ! Now, loop over the nodes in the connectivity and register the element with these nodes
            do inode_elem = 1, size(connectivity)
                
                inode = connectivity(inode_elem)
                node_reg_failed = .false.
                do ireg = 1, MAX_ELEMENTS_PER_NODE
                    if (self%nodes_elems(inode, ireg) == NO_ELEMENT) then
                        ! We have found the first unused entry, which we overwrite, then exit the ireg loop
                        self%nodes_elems(inode, ireg) = ielement_l
                        exit  
                    else
                        ! Check if we have already filled out the node registration storage,
                        ! so that we are unable to register the present element.
                        ! This should only happen if, somehow, a node belongs to more than
                        ! MAX_ELEMENT_PER_NODE number of elements.
                        ! For hexahedral meshes, we expect a node to belong to 
                        ! 1 elems - interior
                        ! 2 elems - face (not edge)
                        ! 4 elems - face edge (not vertex)
                        ! 8 elems - vertex
                        ! with fewer on boundaries. 
                        ! Hence, we set MAX_ELEMENTS_PER_NODE = 8 in mod_constants.
                        if (ireg == MAX_ELEMENTS_PER_NODE) node_reg_failed = .true.
                        ! Add some signalling here...
                    end if

                end do

            end do




        end do ! ielem


    end subroutine init_elems_geom
    !*****************************************************************************************






    !>  Mesh - element solution data initialization
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!  @param[in]  nfields     Number of equations in the domain equation set
    !!  @param[in]  nterms_s    Number of terms in the solution expansion
    !!
    !!  @author Mayank Sharma + Matteo Ugolotti
    !!  @date   11/5/2016
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_elems_sol(self,interpolation,level,nterms_s,nfields,ntime)
        class(domain_t),    intent(inout)   :: self
        character(*),       intent(in)      :: interpolation
        integer(ik),        intent(in)      :: level
        integer(ik),        intent(in)      :: nterms_s
        integer(ik),        intent(in)      :: nfields
        integer(ik),        intent(in)      :: ntime
        integer(ik)                         :: ielem

        integer(ik) :: dof_start, dof_local_start, xdof_start, xdof_local_start

        ! Store number of equations and number of terms in the solution expansion
        self%nfields  = nfields
        self%nterms_s = nterms_s
        self%ntime    = ntime


        ! Call the numerics initialization procedure for each element
        do ielem = 1,self%nelem
            ! Compute dof starting index
            if (ielem == 1) then
                dof_start        = self%domain_dof_start
                dof_local_start  = self%domain_dof_local_start
                xdof_start       = self%domain_xdof_start
                xdof_local_start = self%domain_xdof_local_start
            else
                ! TODO: Fix for adaptive. Assumes constant nterms, ntime, nfields
                dof_start        = self%elems(ielem-1)%dof_start        + nterms_s*nfields*ntime
                dof_local_start  = self%elems(ielem-1)%dof_local_start  + nterms_s*nfields*ntime
                xdof_start       = self%elems(ielem-1)%xdof_start       + self%elems(ielem-1)%nterms_c*3*ntime
                xdof_local_start = self%elems(ielem-1)%xdof_local_start + self%elems(ielem-1)%nterms_c*3*ntime
            end if

            call self%elems(ielem)%init_sol(interpolation,level,self%nterms_s,self%nfields,ntime,dof_start,dof_local_start,xdof_start,xdof_local_start)
        end do


    end subroutine init_elems_sol
    !*****************************************************************************************






    !>  Mesh - face initialization procedure
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_faces_geom(self)
        class(domain_t),                intent(inout)   :: self

        integer(ik)     :: ielem, iface, ierr

        ! Allocate face storage array
        allocate(self%faces(self%nelem,NFACES),stat=ierr)
        if (ierr /= 0) call chidg_signal(FATAL,"mesh%init_faces_geom -- face allocation error")

        ! Loop through each element and call initialization for each face
        do ielem = 1,self%nelem
            do iface = 1,NFACES
                call self%faces(ielem,iface)%init_geom(iface,self%elems(ielem))
            end do !iface
        end do !ielem

    end subroutine init_faces_geom
    !*****************************************************************************************






    !>  Mesh - face initialization procedure
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !------------------------------------------------------------------------------------------
    subroutine init_faces_sol(self)
        class(domain_t), intent(inout)  :: self

        integer(ik) :: ielem, iface

        ! Loop through elements, faces and call initialization that depends on 
        ! the solution basis.
        do ielem = 1,self%nelem
            do iface = 1,NFACES
                call self%faces(ielem,iface)%init_sol(self%elems(ielem))
            end do ! iface
        end do ! ielem

    end subroutine init_faces_sol
    !******************************************************************************************






    !>  Compute interpolators derivatives for:
    !!      - the current element and element faces
    !!      - the current neighbor elements' faces  
    !!  
    !!  @authot Matteo Ugolotti
    !!  @date   12/14/2018
    !!
    !------------------------------------------------------------------------------------------
    subroutine compute_interpolations_dx(self,ielem_l)
        class(domain_t),    intent(inout)            :: self
        integer(ik),        intent(in)               :: ielem_l

        integer(ik)     :: iface, n_element_l, n_face, ChiID, idonor
        logical         :: conforming_face, chimera_face, local_neighbor

        ! Compute element interpolators for current element
        call self%elems(ielem_l)%update_interpolations_dx()

        ! Compute face interpolators for all current element faces
        ! and neighrbor's face
        do iface = 1,NFACES

            ! Differentiate current face
            call self%faces(ielem_l,iface)%update_interpolations_dx(self%elems(ielem_l))

            ! Differentiate adjecent neighbor's face
            conforming_face  = ( self%faces(ielem_l,iface)%ftype == INTERIOR )
            chimera_face     = ( self%faces(ielem_l,iface)%ftype == CHIMERA )
            local_neighbor   = ( self%faces(ielem_l,iface)%ineighbor_proc == IRANK)

            if ( conforming_face ) then
                if ( local_neighbor ) then
                    ! Compute local neighbor element and face intepolators
                    ! NB: here the element dx interpolators have to intialized 
                    !     because dinvmass_dx is needed for BR2 matrices
                    n_element_l = self%faces(ielem_l,iface)%ineighbor_element_l
                    n_face      = self%faces(ielem_l,iface)%ineighbor_face
                    call self%elems(n_element_l)%update_interpolations_dx()
                    call self%faces(n_element_l,n_face)%update_interpolations_dx(self%elems(n_element_l))
                else
                    ! Compute parallel neighbor face interpolators
                    call self%faces(ielem_l,iface)%update_neighbor_interpolations_dx()
                end if

            else if ( chimera_face ) then
                ! Compute differentiated interpolator for chimera donors
                ChiID = self%faces(ielem_l,iface)%ChiID
                do idonor = 1,self%chimera%recv(ChiID)%ndonors()
                    call self%chimera%recv(ChiID)%donor(idonor)%update_interpolations_dx()
                end do
            end if
        end do

    end subroutine compute_interpolations_dx
    !******************************************************************************************









    !>  Release interpolators derivatives for a specific element and neighbors' face
    !!  
    !!
    !!  @authot Matteo Ugolotti
    !!  @date   12/14/2018
    !!
    !------------------------------------------------------------------------------------------
    subroutine release_interpolations_dx(self,ielem_l)
        class(domain_t),    intent(inout)            :: self
        integer(ik),        intent(in)               :: ielem_l

        integer(ik)     :: iface, n_element_l, n_face, ChiID, idonor
        logical         :: conforming_face, chimera_face, local_neighbor
        
        ! Release element interpolators for current element
        call self%elems(ielem_l)%release_interpolations_dx()

        ! Release memeory for face interpolators for all current element faces
        ! and neighrbor's face
        do iface = 1,NFACES

            ! Release memory for current face
            call self%faces(ielem_l,iface)%release_interpolations_dx()

            ! Release memory for adjacent neighbor's face
            conforming_face  = ( self%faces(ielem_l,iface)%ftype == INTERIOR )
            chimera_face     = ( self%faces(ielem_l,iface)%ftype == CHIMERA )
            local_neighbor   = ( self%faces(ielem_l,iface)%ineighbor_proc == IRANK)

            if ( conforming_face ) then
                if ( local_neighbor ) then
                    ! Release local neighbor face intepolators
                    n_element_l = self%faces(ielem_l,iface)%ineighbor_element_l
                    n_face      = self%faces(ielem_l,iface)%ineighbor_face

                    call self%elems(n_element_l)%release_interpolations_dx()
                    call self%faces(n_element_l,n_face)%release_interpolations_dx()
                else
                    ! Release parallel neighbor face interpolators
                    call self%faces(ielem_l,iface)%release_neighbor_interpolations_dx()
                end if
            else if ( chimera_face ) then
                ! Release differentiated interpolator for chimera donors
                ChiID = self%faces(ielem_l,iface)%ChiID
                do idonor = 1,self%chimera%recv(ChiID)%ndonors()
                    call self%chimera%recv(ChiID)%donor(idonor)%release_interpolations_dx()
                end do
            end if
        end do

    end subroutine release_interpolations_dx
    !******************************************************************************************









    !> Compute area weighted version of h. Adapted from:
    !! Schoenawa, Stefan, and Ralf Hartmann. 
    !! "Discontinuous Galerkin discretization of the Reynolds-averaged Navier–Stokes equations with the shear-stress transport model." 
    !! Journal of Computational Physics 262 (2014): 194-216.
    !!
    !! @author  Eric M. Wolf
    !! @date    03/05/2019 
    !!
    !--------------------------------------------------------------------------------
    subroutine compute_area_weighted_h(self)
        class(domain_t), intent(inout)  :: self

        integer(ik) :: ielem, iface

        real(rk) :: vol, normal_integral(3), svec(3), awhvec(3)
        !
        ! Loop through elements, faces and call initialization that depends on 
        ! the solution basis.
        !
        do ielem = 1,self%nelem
            vol = self%elems(ielem)%vol
            normal_integral = ZERO
            do iface = 1,NFACES
                normal_integral = normal_integral + self%faces(ielem,iface)%compute_projected_areas()
            end do ! iface

            svec = TWO*vol/normal_integral
            awhvec = svec*sqrt(vol/(svec(1)*svec(2)*svec(3)))

            self%elems(ielem)%area_weighted_h = awhvec
        end do ! ielem


    end subroutine compute_area_weighted_h 
    !******************************************************************************************









    !>  Initialize processor-local, interior neighbor communication.
    !!
    !!  For each face without an interior neighbor, search the current mesh for a 
    !!  potential neighbor element/face by trying to match the corner indices of the elements.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/10/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_comm_local(self)
        class(domain_t),    intent(inout)   :: self

        integer(ik)             :: iface,ftype,ielem,ierr, ielem_neighbor,              &
                                   ineighbor_domain_g,   ineighbor_domain_l,            &
                                   ineighbor_element_g,  ineighbor_element_l,           &
                                   ineighbor_face,       ineighbor_proc,                &
                                   ineighbor_nfields,    ineighbor_nterms_s,            &
                                   ineighbor_ntime,      ineighbor_nnodes_r,            &
                                   ineighbor_dof_start,  ineighbor_dof_local_start,     &
                                   ineighbor_xdof_start, ineighbor_xdof_local_start,    &
                                   neighbor_status, idomain_g, idomain_l, ielement_g,   &
                                   ielement_l, nterms_s, nfields, ntime, nnodes_r,      &
                                   dof_start, dof_local_start, xdof_start, xdof_local_start

        logical :: orphan_face, local_interior_face, parallel_interior_face

        !
        ! Loop through each local element and call initialization for each face
        !
        do ielem = 1,self%nelem
            do iface = 1,NFACES

                orphan_face            = (self%faces(ielem,iface)%ftype == ORPHAN)
                local_interior_face    = (self%faces(ielem,iface)%ftype == INTERIOR) .and. (self%faces(ielem,iface)%ineighbor_proc == IRANK)
                parallel_interior_face = (self%faces(ielem,iface)%ftype == INTERIOR) .and. (self%faces(ielem,iface)%ineighbor_proc /= IRANK)

                !
                ! Check if face has neighbor on local partition.
                !   - ORPHAN means the exterior state is empty and we want to try and find a connection
                !
                if ( orphan_face ) then
                    call self%find_neighbor_local(ielem,iface,              &
                                                  ineighbor_domain_g,       &
                                                  ineighbor_domain_l,       &
                                                  ineighbor_element_g,      &
                                                  ineighbor_element_l,      &
                                                  ineighbor_face,           &
                                                  ineighbor_proc,           &
                                                  neighbor_status)

                !
                !   - INTERIOR means the neighbor is already connected, but maybe we want to reinitialize
                !     the info, for example nterms_s if the order has been increased. So here,
                !     we just access the location that is already initialized.
                !
                else if ( local_interior_face .or. parallel_interior_face )  then
                    
                    ineighbor_domain_g  = self%faces(ielem,iface)%ineighbor_domain_g
                    ineighbor_domain_l  = self%faces(ielem,iface)%ineighbor_domain_l
                    ineighbor_element_g = self%faces(ielem,iface)%ineighbor_element_g
                    ineighbor_element_l = self%faces(ielem,iface)%ineighbor_element_l
                    ineighbor_face      = self%faces(ielem,iface)%ineighbor_face
                    ineighbor_proc      = self%faces(ielem,iface)%ineighbor_proc
                    neighbor_status     = NEIGHBOR_FOUND

                end if


                    
                !
                ! If no neighbor found, either boundary condition face or chimera face
                !
                if ( orphan_face .or. local_interior_face) then

                    if ( neighbor_status == NEIGHBOR_FOUND ) then

                        ftype                      = INTERIOR
                        ineighbor_nfields          = self%elems(ineighbor_element_l)%nfields
                        ineighbor_ntime            = self%elems(ineighbor_element_l)%ntime
                        ineighbor_nterms_s         = self%elems(ineighbor_element_l)%nterms_s
                        ineighbor_nnodes_r         = self%elems(ineighbor_element_l)%basis_c%nnodes_r()
                        ineighbor_dof_start        = self%elems(ineighbor_element_l)%dof_start
                        ineighbor_dof_local_start  = self%elems(ineighbor_element_l)%dof_local_start
                        ineighbor_xdof_start       = self%elems(ineighbor_element_l)%xdof_start
                        ineighbor_xdof_local_start = self%elems(ineighbor_element_l)%xdof_local_start


                    else
                        ! Default ftype to ORPHAN face and clear neighbor index data.
                        ! ftype should be processed later; either by a boundary conditions (ftype=1), 
                        ! or a chimera boundary (ftype = 2)
                        ftype = ORPHAN
                        ineighbor_domain_g         = 0
                        ineighbor_domain_l         = 0
                        ineighbor_element_g        = 0
                        ineighbor_element_l        = 0
                        ineighbor_face             = 0
                        ineighbor_nfields          = 0
                        ineighbor_ntime            = 0
                        ineighbor_nterms_s         = 0
                        ineighbor_nnodes_r         = 0
                        ineighbor_dof_start        = NO_ID
                        ineighbor_dof_local_start  = NO_ID
                        ineighbor_xdof_start       = NO_ID
                        ineighbor_xdof_local_start = NO_ID
                        ineighbor_proc             = NO_PROC

                    end if


                    !
                    ! Call face neighbor initialization routine
                    !
                    call self%faces(ielem,iface)%set_neighbor(ftype,ineighbor_domain_g,   ineighbor_domain_l,        &
                                                                    ineighbor_element_g,  ineighbor_element_l,       &
                                                                    ineighbor_face,       ineighbor_nfields,         &
                                                                    ineighbor_ntime,      ineighbor_nterms_s,        &
                                                                    ineighbor_nnodes_r,   ineighbor_proc,            &
                                                                    ineighbor_dof_start,  ineighbor_dof_local_start, &
                                                                    ineighbor_xdof_start, ineighbor_xdof_local_start)

                    ! Also, initialize neighbor face at the same time so we don't
                    ! have to do the search again. Only can initialize opposite neighbor if 
                    ! opposite element is on-proc.
                    if ( (neighbor_status == NEIGHBOR_FOUND) .and. (ineighbor_proc == IRANK) ) then
                        idomain_g        = self%elems(ielem)%idomain_g
                        idomain_l        = self%elems(ielem)%idomain_l
                        ielement_g       = self%elems(ielem)%ielement_g
                        ielement_l       = self%elems(ielem)%ielement_l
                        nfields          = self%elems(ielem)%nfields
                        ntime            = self%elems(ielem)%ntime
                        nterms_s         = self%elems(ielem)%nterms_s
                        nnodes_r         = self%elems(ielem)%basis_c%nnodes_r()
                        dof_start        = self%elems(ielem)%dof_start
                        dof_local_start  = self%elems(ielem)%dof_local_start
                        xdof_start       = self%elems(ielem)%xdof_start
                        xdof_local_start = self%elems(ielem)%xdof_local_start
                        call self%faces(ineighbor_element_l,ineighbor_face)%set_neighbor(ftype,idomain_g,  idomain_l,       &
                                                                                               ielement_g, ielement_l,      &
                                                                                               iface,      nfields,         &
                                                                                               ntime,      nterms_s,        &
                                                                                               nnodes_r,   IRANK,           &
                                                                                               dof_start,  dof_local_start, &
                                                                                               xdof_start, xdof_local_start)
                    end if

                end if

            end do !iface
        end do !ielem


        ! Set initialized
        self%local_comm_initialized = .true.

    end subroutine init_comm_local
    !*****************************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/17/2016
    !!
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine init_comm_global(self,ChiDG_COMM)
        class(domain_t),    intent(inout)   :: self
        type(mpi_comm),     intent(in)      :: ChiDG_COMM

        integer(ik)  :: iface,ftype,idomain_g, ielem,ierr, iface_search, iproc,  &
                        ineighbor_domain_g,   ineighbor_domain_l,         &
                        ineighbor_element_g,  ineighbor_element_l,        &
                        ineighbor_face,       ineighbor_proc,             &
                        ineighbor_nfields,    ineighbor_ntime,            &
                        ineighbor_nterms_s,   ineighbor_nnodes_r,         &
                        ineighbor_dof_start,  ineighbor_dof_local_start,  &
                        ineighbor_xdof_start, ineighbor_xdof_local_start, &
                        neighbor_status

        real(rk)                                :: neighbor_h(3)
        real(rk), allocatable, dimension(:,:)   :: neighbor_grad1,   neighbor_grad2,    &
                                                   neighbor_grad3,   neighbor_br2_face, &
                                                   neighbor_br2_vol, neighbor_invmass,  &
                                                   neighbor_coords

        logical :: searching, orphan_face, parallel_interior_face

        integer(ik) :: grad_size(2), br2_face_size(2), br2_vol_size(2), invmass_size(2), data(11), coords_size
        integer(ik) :: corner_one, corner_two, corner_three, corner_four, mapping
        integer(ik), allocatable :: face_search_corners(:,:), face_owner_rank(:), face_owner_rank_reduced(:)
        integer(ik) :: nfaces_search

        ! Accumulate number of faces to be searched 
        nfaces_search = 0
        do ielem = 1,self%nelem
            do iface = 1,NFACES

                orphan_face            = (self%faces(ielem,iface)%ftype == ORPHAN)
                parallel_interior_face = (self%faces(ielem,iface)%ftype == INTERIOR) .and. (self%faces(ielem,iface)%ineighbor_proc /= IRANK)

                ! Check if face has neighbor on another MPI rank.
                !
                !   Do this for ORPHAN faces, that are looking for a potential neighbor
                !   Do this also for INTERIOR faces with off-processor neighbors, in case 
                !   this is being called as a reinitialization routine, so that 
                !   element-specific information gets updated, such as neighbor_grad1, 
                !   etc. because these could have changed if the order of the solution changed
                !
                if (orphan_face .or. parallel_interior_face) then
                   nfaces_search = nfaces_search + 1
                end if !search_face

            end do !iface
        end do !ielem


        ! Allocate face_corners(nfaces_search,ncorners)
        allocate(face_search_corners(nfaces_search,NFACE_CORNERS), &
                 face_owner_rank(nfaces_search), &
                 face_owner_rank_reduced(nfaces_search), stat=ierr)
        if (ierr /= 0) call AllocationError


        ! None of this information should be coming from the current 
        ! rank so we initialize it to default NO_PROC
        face_owner_rank = NO_PROC
        face_owner_rank_reduced = NO_PROC


        ! Broadcast information about faces being searched
        call MPI_BCast(nfaces_search,1,MPI_INTEGER4,IRANK,ChiDG_COMM,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'domain%init_comm_global: error broadcasting number of faces for parallel search.')


        ! Fill face_corner information to broadcast
        iface_search = 0
        do ielem = 1,self%nelem
            do iface = 1,NFACES

                orphan_face            = (self%faces(ielem,iface)%ftype == ORPHAN)
                parallel_interior_face = (self%faces(ielem,iface)%ftype == INTERIOR) .and. (self%faces(ielem,iface)%ineighbor_proc /= IRANK)

                if (orphan_face .or. parallel_interior_face) then

                    iface_search = iface_search + 1

                    ! Get the indices of the corner nodes that correspond to the current face 
                    ! in an element connectivity list.
                    mapping      = self%elems(ielem)%element_type
                    corner_one   = FACE_CORNERS(iface,1,mapping)
                    corner_two   = FACE_CORNERS(iface,2,mapping)
                    corner_three = FACE_CORNERS(iface,3,mapping)
                    corner_four  = FACE_CORNERS(iface,4,mapping)

                    ! For the current face, get the indices of the coordinate nodes for 
                    ! the corners defining a face
                    face_search_corners(iface_search,1) = self%elems(ielem)%connectivity(corner_one)
                    face_search_corners(iface_search,2) = self%elems(ielem)%connectivity(corner_two)
                    face_search_corners(iface_search,3) = self%elems(ielem)%connectivity(corner_three)
                    face_search_corners(iface_search,4) = self%elems(ielem)%connectivity(corner_four)
                end if !search_face

            end do !iface
        end do !ielem


        ! Broadcast face corners
        call MPI_BCast(face_search_corners,nfaces_search*NFACE_CORNERS,MPI_INTEGER4,IRANK,ChiDG_COMM,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'domain%init_comm_global: error broadcasting face corner indices.')


        ! Reduce face owners
        call MPI_Reduce(face_owner_rank,face_owner_rank_reduced,nfaces_search,MPI_INTEGER4,MPI_MAX,IRANK,ChiDG_COMM,ierr)
        if (ierr /= 0) call chidg_signal(FATAL,'mesh%init_comm_global: error reducing face owners.')



        ! For each face found, receive neighbor info from owner rank
        iface_search = 0
        do ielem = 1,self%nelem
            do iface = 1,NFACES

                orphan_face            = (self%faces(ielem,iface)%ftype == ORPHAN)
                parallel_interior_face = (self%faces(ielem,iface)%ftype == INTERIOR) .and. (self%faces(ielem,iface)%ineighbor_proc /= IRANK)

                if (orphan_face .or. parallel_interior_face) then

                    iface_search = iface_search + 1
                    if (face_owner_rank_reduced(iface_search) /= NO_PROC) then

                        iproc = face_owner_rank_reduced(iface_search)

                        call MPI_Recv(data,11,MPI_INTEGER4,iproc,4,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)
                        ineighbor_domain_g         = data(1)
                        ineighbor_domain_l         = data(2)
                        ineighbor_element_g        = data(3)
                        ineighbor_element_l        = data(4)
                        ineighbor_face             = data(5)
                        ineighbor_nfields          = data(6)
                        ineighbor_ntime            = data(7)
                        ineighbor_nterms_s         = data(8)
                        ineighbor_nnodes_r         = data(9)
                        ineighbor_dof_start        = data(10)
                        ineighbor_xdof_start       = data(11)
                        ineighbor_dof_local_start  = NO_ID
                        ineighbor_xdof_local_start = NO_ID
                        ineighbor_proc             = iproc

                        call MPI_Recv(grad_size,    2,MPI_INTEGER4,iproc,5,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(br2_face_size,2,MPI_INTEGER4,iproc,6,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(br2_vol_size, 2,MPI_INTEGER4,iproc,7,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(invmass_size, 2,MPI_INTEGER4,iproc,8,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(coords_size,  1,MPI_INTEGER4,iproc,9,ChiDG_COMM,MPI_STATUS_IGNORE,ierr)

                        if (allocated(neighbor_grad1)) deallocate(neighbor_grad1,neighbor_grad2,neighbor_grad3, &
                                                                neighbor_br2_face, neighbor_br2_vol, neighbor_invmass, neighbor_coords)
                        allocate(neighbor_grad1(grad_size(1),grad_size(2)), &
                                 neighbor_grad2(grad_size(1),grad_size(2)), &
                                 neighbor_grad3(grad_size(1),grad_size(2)), &
                                 neighbor_br2_face(br2_face_size(1),br2_face_size(2)), &
                                 neighbor_br2_vol(br2_vol_size(1),br2_vol_size(2)),    &
                                 neighbor_coords(coords_size,3),                         &
                                 neighbor_invmass(invmass_size(1),invmass_size(2)),  stat=ierr)
                        if (ierr /= 0) call AllocationError

                        call MPI_Recv(neighbor_grad1,       grad_size(1)*grad_size(2),          MPI_REAL8, iproc, 10, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_grad2,       grad_size(1)*grad_size(2),          MPI_REAL8, iproc, 11, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_grad3,       grad_size(1)*grad_size(2),          MPI_REAL8, iproc, 12, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_br2_face,    br2_face_size(1)*br2_face_size(2),  MPI_REAL8, iproc, 13, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_br2_vol,     br2_vol_size(1)*br2_vol_size(2),    MPI_REAL8, iproc, 14, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_invmass,     invmass_size(1)*invmass_size(2),    MPI_REAL8, iproc, 15, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_h,           3,                                  MPI_REAL8, iproc, 16, ChiDG_COMM, MPI_STATUS_IGNORE,ierr) 
                        call MPI_Recv(neighbor_coords(:,1), coords_size,                        MPI_REAL8, iproc, 17, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_coords(:,2), coords_size,                        MPI_REAL8, iproc, 18, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)
                        call MPI_Recv(neighbor_coords(:,3), coords_size,                        MPI_REAL8, iproc, 19, ChiDG_COMM, MPI_STATUS_IGNORE,ierr)


                        ! Neighbor data should already be set, from previous routines. 
                        ! Set face type.
                        ftype = INTERIOR

                        ! Set neighbor data
                        self%faces(ielem,iface)%neighbor_h        = neighbor_h
                        self%faces(ielem,iface)%neighbor_grad1    = neighbor_grad1
                        self%faces(ielem,iface)%neighbor_grad2    = neighbor_grad2
                        self%faces(ielem,iface)%neighbor_grad3    = neighbor_grad3
                        self%faces(ielem,iface)%neighbor_br2_face = neighbor_br2_face
                        self%faces(ielem,iface)%neighbor_br2_vol  = neighbor_br2_vol
                        self%faces(ielem,iface)%neighbor_invmass  = neighbor_invmass
                        self%faces(ielem,iface)%neighbor_coords   = neighbor_coords

                    else 

                        ! Default ftype to ORPHAN face and clear neighbor index data.
                        ! ftype should be processed later; either by a boundary 
                        ! condition(ftype=1), or a chimera boundary(ftype=2)
                        ftype = ORPHAN
                        ineighbor_domain_g        = 0
                        ineighbor_domain_l        = 0
                        ineighbor_element_g       = 0
                        ineighbor_element_l       = 0
                        ineighbor_face            = 0
                        ineighbor_nfields         = 0
                        ineighbor_ntime           = 0
                        ineighbor_nterms_s        = 0
                        ineighbor_nnodes_r        = 0
                        ineighbor_dof_start       = NO_ID
                        ineighbor_dof_local_start = NO_ID
                        ineighbor_xdof_start       = NO_ID
                        ineighbor_xdof_local_start = NO_ID
                        ineighbor_proc            = NO_PROC

                    end if

                    ! Call face neighbor initialization routine
                    call self%faces(ielem,iface)%set_neighbor(ftype,ineighbor_domain_g,   ineighbor_domain_l,        &
                                                                    ineighbor_element_g,  ineighbor_element_l,       &
                                                                    ineighbor_face,       ineighbor_nfields,         &
                                                                    ineighbor_ntime,      ineighbor_nterms_s,        &
                                                                    ineighbor_nnodes_r,   ineighbor_proc,            &
                                                                    ineighbor_dof_start,  ineighbor_dof_local_start, &
                                                                    ineighbor_xdof_start, ineighbor_xdof_local_start)


                end if ! search_face

            end do !iface
        end do !ielem

        ! Set initialized
        self%global_comm_initialized = .true.

    end subroutine init_comm_global
    !*****************************************************************************************






    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   8/9/2018
    !!
    !-----------------------------------------------------------------------------------------
    subroutine find_face_owner(self,face_search_corners,face_owner_rank)
        class(domain_t),    intent(inout)   :: self
        integer(ik),        intent(in)      :: face_search_corners(:,:)
        integer(ik),        intent(inout)   :: face_owner_rank(:)

        integer(ik) :: ielem, iface_search
        logical     :: includes_corner_one, includes_corner_two, &
                       includes_corner_three, includes_corner_four, neighbor_element

        ! For each face being searched for, search local elements to try and find match
        neighbor_element = .false.
        do iface_search = 1,size(face_search_corners,1)

            ! Search local elements for match
            do ielem = 1,self%nelem
                includes_corner_one   = any( self%elems(ielem)%connectivity == face_search_corners(iface_search,1) )
                includes_corner_two   = any( self%elems(ielem)%connectivity == face_search_corners(iface_search,2) )
                includes_corner_three = any( self%elems(ielem)%connectivity == face_search_corners(iface_search,3) )
                includes_corner_four  = any( self%elems(ielem)%connectivity == face_search_corners(iface_search,4) )
                neighbor_element = ( includes_corner_one   .and. &
                                     includes_corner_two   .and. &
                                     includes_corner_three .and. &
                                     includes_corner_four )

                if ( neighbor_element ) then
                    face_owner_rank(iface_search) = IRANK
                    exit
                end if

            end do ! ielem

        end do !iface_search

    end subroutine find_face_owner
    !****************************************************************************************






    !>  Outside of this subroutine, it should have already been determined that a 
    !!  neighbor request was initiated from another processor and the current processor 
    !!  contains part of the domain of interest. This routine receives corner indices from 
    !!  the requesting processor and tries to find a match in the current mesh. The status 
    !!  of the element match is sent back. If a match was 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/21/2016
    !!
    !-----------------------------------------------------------------------------------------
    subroutine transmit_face_info(self,face_search_corners,face_owner_rank,iproc,ChiDG_COMM)
        class(domain_t),    intent(inout)   :: self
        integer(ik),        intent(in)      :: face_search_corners(:,:)
        integer(ik),        intent(in)      :: face_owner_rank(:)
        integer(ik),        intent(in)      :: iproc
        type(mpi_comm),     intent(in)      :: ChiDG_COMM

        integer(ik) :: ielem_l, iface, ierr, iface_search,                  &
                       ineighbor_domain_g, ineighbor_domain_l,              &
                       ineighbor_element_g, ineighbor_element_l,            &
                       ineighbor_face, ineighbor_nfields, ineighbor_ntime,  &
                       ineighbor_nterms_s, ineighbor_nnodes_r,              &
                       ineighbor_dof_start, ineighbor_xdof_start, data(11), &
                       grad_size(2), invmass_size(2), br2_face_size(2), br2_vol_size(2), coords_size
        logical     :: includes_corner_one, includes_corner_two, &
                       includes_corner_three, includes_corner_four, neighbor_element

        
        do iface_search = 1,size(face_owner_rank)

            ! Did we say we had this face?
            if (face_owner_rank(iface_search) == IRANK) then

                ! Loop through local domain and try to find a match
                ! Test the incoming face nodes against local elements, if all face nodes are 
                ! also contained in an element, then they are neighbors.
                neighbor_element = .false.
                do ielem_l = 1,self%nelem
                    includes_corner_one   = any( self%elems(ielem_l)%connectivity == face_search_corners(iface_search,1) )
                    includes_corner_two   = any( self%elems(ielem_l)%connectivity == face_search_corners(iface_search,2) )
                    includes_corner_three = any( self%elems(ielem_l)%connectivity == face_search_corners(iface_search,3) )
                    includes_corner_four  = any( self%elems(ielem_l)%connectivity == face_search_corners(iface_search,4) )
                    neighbor_element = ( includes_corner_one   .and. &
                                         includes_corner_two   .and. &
                                         includes_corner_three .and. &
                                         includes_corner_four )

                    if ( neighbor_element ) then

                        ! Get indices for neighbor element
                        ineighbor_domain_g   = self%elems(ielem_l)%idomain_g
                        ineighbor_domain_l   = self%elems(ielem_l)%idomain_l
                        ineighbor_element_g  = self%elems(ielem_l)%ielement_g
                        ineighbor_element_l  = self%elems(ielem_l)%ielement_l
                        ineighbor_nfields    = self%elems(ielem_l)%nfields
                        ineighbor_ntime      = self%elems(ielem_l)%ntime
                        ineighbor_nterms_s   = self%elems(ielem_l)%nterms_s
                        ineighbor_nnodes_r   = self%elems(ielem_l)%basis_c%nnodes_r()
                        ineighbor_dof_start  = self%elems(ielem_l)%dof_start
                        ineighbor_xdof_start = self%elems(ielem_l)%xdof_start

                        
                        ! Get face index connected to the requesting element
                        iface = self%elems(ielem_l)%get_face_from_corners(face_search_corners(iface_search,:))
                        ineighbor_face = iface

                        data = [ineighbor_domain_g,  ineighbor_domain_l,    &
                                ineighbor_element_g, ineighbor_element_l,   &
                                ineighbor_face,      ineighbor_nfields,     &
                                ineighbor_ntime,     ineighbor_nterms_s,    &
                                ineighbor_nnodes_r,  ineighbor_dof_start, ineighbor_xdof_start]


                        ! Send face location
                        call MPI_Send(data,11,MPI_INTEGER4,iproc,4,ChiDG_COMM,ierr)

                        ! Send Element Data
                        grad_size(1)     = size(self%faces(ielem_l,iface)%grad1,1)
                        grad_size(2)     = size(self%faces(ielem_l,iface)%grad1,2)
                        br2_face_size(1) = size(self%faces(ielem_l,iface)%br2_face,1)
                        br2_face_size(2) = size(self%faces(ielem_l,iface)%br2_face,2)
                        br2_vol_size(1)  = size(self%faces(ielem_l,iface)%br2_vol,1)
                        br2_vol_size(2)  = size(self%faces(ielem_l,iface)%br2_vol,2)
                        invmass_size(1)  = size(self%elems(ielem_l)%invmass,1)
                        invmass_size(2)  = size(self%elems(ielem_l)%invmass,2)
                        coords_size      = self%elems(ielem_l)%coords%nterms() 

                        call MPI_Send(grad_size,    2,MPI_INTEGER4,iproc,5,ChiDG_COMM,ierr)
                        call MPI_Send(br2_face_size,2,MPI_INTEGER4,iproc,6,ChiDG_COMM,ierr)
                        call MPI_Send(br2_vol_size, 2,MPI_INTEGER4,iproc,7,ChiDG_COMM,ierr)
                        call MPI_Send(invmass_size, 2,MPI_INTEGER4,iproc,8,ChiDG_COMM,ierr)
                        call MPI_Send(coords_size,  1,MPI_INTEGER4,iproc,9,ChiDG_COMM,ierr)

                        call MPI_Send(self%faces(ielem_l,iface)%grad1,              grad_size(1)*grad_size(2),          MPI_REAL8,iproc,10,ChiDG_COMM,ierr)
                        call MPI_Send(self%faces(ielem_l,iface)%grad2,              grad_size(1)*grad_size(2),          MPI_REAL8,iproc,11,ChiDG_COMM,ierr)
                        call MPI_Send(self%faces(ielem_l,iface)%grad3,              grad_size(1)*grad_size(2),          MPI_REAL8,iproc,12,ChiDG_COMM,ierr)
                        call MPI_Send(self%faces(ielem_l,iface)%br2_face,           br2_face_size(1)*br2_face_size(2),  MPI_REAL8,iproc,13,ChiDG_COMM,ierr)
                        call MPI_Send(self%faces(ielem_l,iface)%br2_vol,            br2_vol_size(1)*br2_vol_size(2),    MPI_REAL8,iproc,14,ChiDG_COMM,ierr)
                        call MPI_Send(self%elems(ielem_l)%invmass,                  invmass_size(1)*invmass_size(2),    MPI_REAL8,iproc,15,ChiDG_COMM,ierr)
                        call MPI_Send(self%elems(ielem_l)%h,                        3,                                  MPI_REAL8,iproc,16,ChiDG_COMM,ierr)
                        call MPI_Send(self%elems(ielem_l)%coords%getvar(1,itime=1), coords_size,                        MPI_REAL8,iproc,17,ChiDG_COMM,ierr)
                        call MPI_Send(self%elems(ielem_l)%coords%getvar(2,itime=1), coords_size,                        MPI_REAL8,iproc,18,ChiDG_COMM,ierr)
                        call MPI_Send(self%elems(ielem_l)%coords%getvar(3,itime=1), coords_size,                        MPI_REAL8,iproc,19,ChiDG_COMM,ierr)


                        exit
                    end if

                end do ! ielem_l
                                        

            end if !face_owner_rank

        end do !iface_search


    end subroutine transmit_face_info
    !*****************************************************************************************








    !>  For given element/face indices, try to find a potential interior neighbor. That is, 
    !!  a matching element within the current domain and on the current processor(local).
    !!
    !!  If found, return neighbor info.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/16/2016
    !!
    !-----------------------------------------------------------------------------------------
    subroutine find_neighbor_local(self,ielement_l,iface,ineighbor_domain_g, ineighbor_domain_l,   &
                                                      ineighbor_element_g,ineighbor_element_l,  &
                                                      ineighbor_face,     ineighbor_proc,       &
                                                      neighbor_status)
        class(domain_t),    intent(inout)   :: self
        integer(ik),        intent(in)      :: ielement_l
        integer(ik),        intent(in)      :: iface
        integer(ik),        intent(inout)   :: ineighbor_domain_g
        integer(ik),        intent(inout)   :: ineighbor_domain_l
        integer(ik),        intent(inout)   :: ineighbor_element_g
        integer(ik),        intent(inout)   :: ineighbor_element_l
        integer(ik),        intent(inout)   :: ineighbor_face
        integer(ik),        intent(inout)   :: ineighbor_proc
        integer(ik),        intent(inout)   :: neighbor_status

        integer(ik),    allocatable :: element_nodes(:)
        integer(ik) :: corner_one, corner_two, corner_three, corner_four,   &
                       corner_indices(4), ielem_neighbor, mapping
        logical     :: includes_corner_one, includes_corner_two, &
                       includes_corner_three, includes_corner_four, neighbor_element

        neighbor_status = NO_NEIGHBOR_FOUND

        !
        ! Get the element-local node indices of the corner nodes that correspond 
        ! to the current face in an element connectivity list
        !
        mapping = self%elems(ielement_l)%element_type
        corner_one   = FACE_CORNERS(iface,1,mapping)
        corner_two   = FACE_CORNERS(iface,2,mapping)
        corner_three = FACE_CORNERS(iface,3,mapping)
        corner_four  = FACE_CORNERS(iface,4,mapping)

        
        !
        ! For the current face, get the global-indices of the coordinate nodes 
        ! for the corners
        !
        corner_indices(1) = self%elems(ielement_l)%connectivity(corner_one)
        corner_indices(2) = self%elems(ielement_l)%connectivity(corner_two)
        corner_indices(3) = self%elems(ielement_l)%connectivity(corner_three)
        corner_indices(4) = self%elems(ielement_l)%connectivity(corner_four)

        
        !
        ! Test the global face node indices against other elements. If all face nodes 
        ! are also contained in another element, then they are neighbors.
        !
        neighbor_element = .false.
        do ielem_neighbor = 1,self%nelem
            if (ielem_neighbor /= ielement_l) then

                !element_nodes = self%elems(ielem_neighbor)%connectivity%get_element_nodes()
                element_nodes = self%elems(ielem_neighbor)%connectivity
                includes_corner_one   = any( element_nodes == corner_indices(1) )
                includes_corner_two   = any( element_nodes == corner_indices(2) )
                includes_corner_three = any( element_nodes == corner_indices(3) )
                includes_corner_four  = any( element_nodes == corner_indices(4) )

                neighbor_element = ( includes_corner_one   .and. &
                                     includes_corner_two   .and. &
                                     includes_corner_three .and. &
                                     includes_corner_four )

                if ( neighbor_element ) then
                    ineighbor_domain_g  = self%elems(ielem_neighbor)%idomain_g
                    ineighbor_domain_l  = self%elems(ielem_neighbor)%idomain_l
                    ineighbor_element_g = self%elems(ielem_neighbor)%ielement_g
                    ineighbor_element_l = self%elems(ielem_neighbor)%ielement_l
                    ineighbor_face      = self%elems(ielem_neighbor)%get_face_from_corners(corner_indices)
                    ineighbor_proc      = IRANK
                    neighbor_status     = NEIGHBOR_FOUND
                    exit
                end if

            end if
        end do


    end subroutine find_neighbor_local
    !*****************************************************************************************






    !>  Return the processor ranks that the current mesh is receiving from.
    !!
    !!  This includes interior neighbor elements located on another processor and also chimera
    !!  donor elements located on another processor.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !-----------------------------------------------------------------------------------------
    function get_recv_procs(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        type(ivector_t)             :: comm_procs_vector
        integer(ik),    allocatable :: comm_procs(:), comm_procs_local(:), comm_procs_chimera(:)
        integer(ik)                 :: iproc, proc

        ! Test if global communication has been initialized
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,"mesh%get_recv_procs: mesh global communication not initialized")


        ! Get procs we are receiving neighbor data from
        comm_procs_local = self%get_recv_procs_local()
        do iproc = 1,size(comm_procs_local)
            proc = comm_procs_local(iproc)
            call comm_procs_vector%push_back_unique(proc)
        end do !iproc


        ! Get procs we are receiving chimera donors from
        comm_procs_chimera = self%get_recv_procs_chimera()
        do iproc = 1,size(comm_procs_chimera)
            proc = comm_procs_chimera(iproc)
            call comm_procs_vector%push_back_unique(proc)
        end do !iproc


        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()


    end function get_recv_procs
    !*****************************************************************************************







    !>  Return the processor ranks that the current mesh is receiving interior 
    !!  neighbor elements from.
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function get_recv_procs_local(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        type(ivector_t)             :: comm_procs_vector
        integer(ik),    allocatable :: comm_procs(:)
        integer(ik)                 :: myrank, neighbor_rank, ielem, iface
        logical                     :: has_neighbor, comm_neighbor
        character(:),   allocatable :: user_msg

        ! Test if global communication has been initialized
        user_msg = "mesh%get_comm_procs: mesh global communication not initialized."
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,user_msg)

        ! Get current processor rank
        myrank = IRANK

        do ielem = 1,self%nelem
            do iface = 1,size(self%faces,2)

                ! Get face properties
                has_neighbor = ( self%faces(ielem,iface)%ftype == INTERIOR )
                ! For interior neighbor
                if ( has_neighbor ) then
                    ! Get neighbor processor rank. If off-processor, add to list uniquely
                    neighbor_rank = self%faces(ielem,iface)%ineighbor_proc
                    comm_neighbor = ( myrank /= neighbor_rank )
                    if ( comm_neighbor ) call comm_procs_vector%push_back_unique(neighbor_rank)
                end if

            end do !iface
        end do !ielem

        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()

    end function get_recv_procs_local
    !*****************************************************************************************











    !>  Return the processor ranks that the current mesh is receiving chimera donor 
    !!  elements from.
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function get_recv_procs_chimera(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        character(:),   allocatable :: user_msg
        integer(ik),    allocatable :: comm_procs(:)
        integer(ik)                 :: myrank, ielem, iface, ChiID, idonor, donor_rank
        logical                     :: is_chimera, comm_donor
        type(ivector_t)             :: comm_procs_vector

        ! Test if global communication has been initialized
        user_msg = "mesh%get_recv_procs_chimera: mesh global communication not initialized."
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,user_msg)

        ! Get current processor rank
        myrank = IRANK

        do ielem = 1,self%nelem
            do iface = 1,size(self%faces,2)

                ! Get face properties
                is_chimera   = ( self%faces(ielem,iface)%ftype == CHIMERA  )
                if ( is_chimera ) then
                    ! Loop through donor elements. If off-processor, add to list uniquely
                    ChiID = self%faces(ielem,iface)%ChiID
                    do idonor = 1,self%chimera%recv(ChiID)%ndonors()
                        donor_rank = self%chimera%recv(ChiID)%donor(idonor)%elem_info%iproc
                        comm_donor = ( myrank /= donor_rank )
                        if ( comm_donor ) call comm_procs_vector%push_back_unique(donor_rank)
                    end do !idonor
                end if !is_chimera

            end do !iface
        end do !ielem

        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()

    end function get_recv_procs_chimera
    !*****************************************************************************************










    !>  Return the processor ranks that the current mesh is sending to.
    !!
    !!  This includes processors that are being sent interior neighbor elements and also 
    !!  chimera donor elements.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function get_send_procs(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        type(ivector_t)             :: comm_procs_vector
        integer(ik),    allocatable :: comm_procs(:), comm_procs_local(:), comm_procs_chimera(:)
        integer(ik)                 :: iproc, proc
        character(:),   allocatable :: user_msg


        ! Test if global communication has been initialized
        user_msg = "mesh%get_send_procs: mesh global communication not initialized."
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,user_msg)

        ! Get procs we are receiving neighbor data from
        comm_procs_local = self%get_send_procs_local()
        do iproc = 1,size(comm_procs_local)
            proc = comm_procs_local(iproc)
            call comm_procs_vector%push_back_unique(proc)
        end do !iproc

        ! Get procs we are receiving chimera donors from
        comm_procs_chimera = self%get_send_procs_chimera()
        do iproc = 1,size(comm_procs_chimera)
            proc = comm_procs_chimera(iproc)
            call comm_procs_vector%push_back_unique(proc)
        end do !iproc

        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()


    end function get_send_procs
    !*****************************************************************************************








    !>  Return the processor ranks that the current mesh is sending to.
    !!
    !!  This includes processors that are being sent interior neighbor elements.
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function get_send_procs_local(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        type(ivector_t)             :: comm_procs_vector
        integer(ik),    allocatable :: comm_procs(:)
        integer(ik)                 :: myrank, neighbor_rank, ielem, iface
        logical                     :: has_neighbor, comm_neighbor
        character(:),   allocatable :: user_msg

        ! Test if global communication has been initialized
        user_msg = "mesh%get_send_procs_local: mesh global communication not initialized."
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,user_msg)

        ! Get current processor rank
        myrank = IRANK

        do ielem = 1,self%nelem
            do iface = 1,size(self%faces,2)

                ! Get face properties
                has_neighbor = ( self%faces(ielem,iface)%ftype == INTERIOR )
                ! For interior neighbor
                if ( has_neighbor ) then
                    ! Get neighbor processor rank. If off-processor add to list uniquely
                    neighbor_rank = self%faces(ielem,iface)%ineighbor_proc
                    comm_neighbor = ( myrank /= neighbor_rank )
                    if ( comm_neighbor ) call comm_procs_vector%push_back_unique(neighbor_rank)
                end if

            end do !iface
        end do !ielem

        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()

    end function get_send_procs_local
    !*****************************************************************************************











    !>  Return the processor ranks that the current mesh is sending to.
    !!
    !!  This includes processors that are being sent chimera donor elements.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/30/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    function get_send_procs_chimera(self) result(comm_procs)
        class(domain_t),   intent(in)  :: self

        type(ivector_t)             :: comm_procs_vector
        integer(ik),    allocatable :: comm_procs(:)
        integer(ik)                 :: myrank, isend_elem, isend_proc, send_rank
        logical                     :: comm_donor
        character(:),   allocatable :: user_msg

        ! Test if global communication has been initialized
        user_msg = "mesh%get_send_procs_chimera: mesh global communication not initialized."
        if ( .not. self%global_comm_initialized) call chidg_signal(WARN,user_msg)

        ! Get current processor rank
        myrank = IRANK

        ! Collect processors that we are sending chimera donor elements to
        do isend_elem = 1,self%chimera%nsend()
            do isend_proc = 1,self%chimera%send(isend_elem)%nsend_procs()

                ! Get donor rank. If off-processor, add to list uniquely.
                send_rank = self%chimera%send(isend_elem)%send_procs%at(isend_proc)
                comm_donor = (myrank /= send_rank)
                if ( comm_donor ) call comm_procs_vector%push_back_unique(send_rank)

            end do !isend_proc
        end do !isend_elem

        ! Set vector data to array to be returned.
        comm_procs = comm_procs_vector%data()

    end function get_send_procs_chimera
    !*****************************************************************************************





    !>  Return the number of elements in the original unpartitioned domain.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    function get_nelements_global(self) result(nelements)
        class(domain_t),   intent(in)  :: self

        integer(ik) :: nelements

        nelements = self%nelements_g

    end function get_nelements_global
    !****************************************************************************************






    !>  Return the number of elements in the local, possibly partitioned, domain.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    function get_nelements_local(self) result(nelements)
        class(domain_t),   intent(in)  :: self

        integer(ik) :: nelements

        nelements = self%nelem

    end function get_nelements_local
    !****************************************************************************************







    !>  Return the starting index of the current domain dof's in the ChiDG-global dof list.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   1/25/2019
    !!
    !----------------------------------------------------------------------------------------
    function get_dof_start(self,dof_type) result(dof_start)
        class(domain_t),    intent(in)  :: self
        character(*),       intent(in)  :: dof_type

        integer(ik) :: dof_start

        select case (trim(dof_type))
            case('primal')
                dof_start = self%domain_dof_start
            case('coordinate')
                dof_start = self%domain_xdof_start
            case default
                call chidg_signal(FATAL,"domain%get_dof_start: invalid input for dof_type.")
        end select

    end function get_dof_start
    !****************************************************************************************





    !>  Return the global dof end index of this domain.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   1/25/2019
    !!
    !----------------------------------------------------------------------------------------
    function get_dof_end(self,dof_type) result(dof_end)
        class(domain_t),    intent(in)  :: self
        character(*),       intent(in)  :: dof_type

        integer(ik) :: dof_end, ielem, dofs

        select case (trim(dof_type))
            case('primal')
                ! Accumulate dof's
                dofs = 0
                do ielem = 1,self%nelements()
                    dofs = dofs + self%elems(ielem)%nfields*self%elems(ielem)%nterms_s*self%elems(ielem)%ntime
                end do
                dof_end = self%domain_dof_start + dofs - 1

            case('coordinate')
                ! Accumulate dof's
                dofs = 0
                do ielem = 1,self%nelements()
                    dofs = dofs + 3*self%elems(ielem)%nterms_c*self%elems(ielem)%ntime
                end do
                dof_end = self%domain_xdof_start + dofs - 1

            case default
                call chidg_signal(FATAL,"domain%get_dof_end: invalid input for dof_type.")
        end select

    end function get_dof_end
    !****************************************************************************************



    !>  Return the starting index of the current domain dof's in the ChiDG-local dof list.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/26/2019
    !!
    !----------------------------------------------------------------------------------------
    function get_dof_local_start(self,dof_type) result(dof_local_start)
        class(domain_t),    intent(in)  :: self
        character(*),       intent(in)  :: dof_type

        integer(ik) :: dof_local_start

        select case (trim(dof_type))
            case('primal')
                dof_local_start = self%domain_dof_local_start
            case('coordinate')
                dof_local_start = self%domain_xdof_local_start
            case default
                call chidg_signal(FATAL,"domain%get_dof_local_start: invalid input for dof_type.")
        end select

    end function get_dof_local_start
    !****************************************************************************************





    !>  Return the local dof end index of this domain.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   6/26/2019
    !!
    !----------------------------------------------------------------------------------------
    function get_dof_local_end(self,dof_type) result(dof_local_end)
        class(domain_t),    intent(in)  :: self
        character(*),       intent(in)  :: dof_type

        integer(ik) :: dof_local_end, ielem, dofs

        select case (trim(dof_type))
            case('primal')
                ! Accumulate dof's
                dofs = 0
                do ielem = 1,self%nelements()
                    dofs = dofs + self%elems(ielem)%nfields*self%elems(ielem)%nterms_s*self%elems(ielem)%ntime
                end do
                dof_local_end = self%domain_dof_local_start + dofs - 1

            case('coordinate')
                ! Accumulate dof's
                dofs = 0
                do ielem = 1,self%nelements()
                    dofs = dofs + 3*self%elems(ielem)%nterms_c*self%elems(ielem)%ntime
                end do
                dof_local_end = self%domain_xdof_local_start + dofs - 1

            case default
                call chidg_signal(FATAL,"domain%get_dof_local_end: invalid input for dof_type.")
        end select

    end function get_dof_local_end
    !****************************************************************************************



    !>
    !!
    !!
    !!
    !-------------------------------------------------------------------------------------
    subroutine destructor(self)
        type(domain_t), intent(inout) :: self

    
    end subroutine destructor
    !*************************************************************************************


end module type_domain
