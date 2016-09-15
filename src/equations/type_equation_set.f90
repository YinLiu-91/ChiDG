module type_equation_set
#include <messenger.h>
    use mod_kinds,                      only: rk,ik
    use mod_constants,                  only: INTERIOR, CHIMERA, DIAG, &
                                              BOUNDARY_ADVECTIVE_FLUX, BOUNDARY_DIFFUSIVE_FLUX,         &
                                              VOLUME_ADVECTIVE_FLUX, VOLUME_DIFFUSIVE_FLUX, BC_FLUX,    &
                                              XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX,     &
                                              BOUNDARY
    use mod_operators,                  only: build_operator
    use mod_DNAD_tools,                 only: element_compute_seed, face_compute_seed

    use type_operator,                  only: operator_t
    use type_operator_wrapper,          only: operator_wrapper_t
    use type_equation,                  only: equation_t
    use type_properties,                only: properties_t
    use type_equationset_function_data, only: equationset_function_data_t
    use type_chidg_worker,              only: chidg_worker_t
    use type_mesh,                      only: mesh_t
    use type_solverdata,                only: solverdata_t
    use type_element_info,              only: element_info_t
    use type_face_info,                 only: face_info_t
    use type_function_info,             only: function_info_t
    use type_properties,                only: properties_t
    use type_bcset,                     only: bcset_t
    implicit none
    private



    !>  Abstract equation-set type. Can be extended to implement a concrete equation set.
    !!      - Contains name and number of equations.
    !!      - Contains properties type with equations and material(ex. fluid) properties and definitions
    !!      - Contains arrays of flux components
    !!
    !!  When a new equation set is defined. It should extend from this abstract type. It must then 
    !!  implement the 'init' function where equations/variables can be added, and fluxes can be 
    !!  added to the definition of the equation set.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2016
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/16/2016
    !!  @note   Reorganized to contain operators instead of fluxes
    !!
    !-------------------------------------------------------------------------------------------------
    type, public :: equation_set_t

        ! Name
        character(len=:),           allocatable :: name 

        ! Properties/Equations
        type(properties_t)                      :: prop

        ! Operators
        type(operator_wrapper_t),   allocatable :: boundary_advective_operator(:)
        type(operator_wrapper_t),   allocatable :: boundary_diffusive_operator(:)
        type(operator_wrapper_t),   allocatable :: volume_advective_operator(:)
        type(operator_wrapper_t),   allocatable :: volume_diffusive_operator(:) 
        type(operator_wrapper_t),   allocatable :: bc_operator(:)

        ! Data for the flux and source functions. Ex how many. This gets passed to a container 
        ! in sdata that keeps track of whether these have been executed or not.
        type(equationset_function_data_t)       :: function_data

    contains

        procedure   :: set_name                             !< Set the name for the set of equations
        procedure   :: get_name                             !< Return the name fo the set of equations

        procedure   :: add_operator
        procedure   :: add_equation                         !< Add an equation, it's string, and index


        procedure   :: compute_boundary_advective_operators !< Compute all the boundary advective operators
        procedure   :: compute_boundary_diffusive_operators !< Compute all the boundary diffusive operators
        procedure   :: compute_volume_advective_operators   !< Compute all the volume advective operators
        procedure   :: compute_volume_diffusive_operators   !< Compute all the volume diffusive operators
        procedure   :: compute_bc_operators                 !< Compute all the bc operators

        procedure   :: get_boundary_ndependent_elements     !< return number elements that a boundary function is depending on
        procedure   :: get_volume_ndependent_elements       !< return number elements that a volume function is depending on

    end type equation_set_t
    !**************************************************************************************************







    !> Interface definitions
    abstract interface
        subroutine self_interface(self)
            import equation_set_t
            class(equation_set_t), intent(inout) :: self
        end subroutine
    end interface


contains





    !> Set name of the equation set.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/28/2016
    !!
    !!  @param[in]  name_string     Character string indicating the name of the equation set
    !!
    !---------------------------------------------------------------------------------------------------------
    subroutine set_name(self,name_string)
        class(equation_set_t),   intent(inout)   :: self
        character(len=*),       intent(in)      :: name_string

        self%name = name_string

    end subroutine set_name
    !*********************************************************************************************************




    !>  Return the name of the equation set.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------------------------
    function get_name(self) result(ename)
        class(equation_set_t),   intent(in)   :: self

        character(len=:),   allocatable :: ename

        ename = self%name

    end function get_name
    !*********************************************************************************************************








    !>  A an equation to the equation set properties
    !!
    !!  Just registers the equation string that is specified. This gets put in the properties container,
    !!  self%prop that stores all the equations being used by the spatial operators.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/28/2016
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/2/2016
    !!  @note   modified how the equations are stored.
    !!
    !!  @param[in]  varstring   String defining the variable associated with the equation being added
    !!  @param[in]  varindex    The index of the equation in the given set. 
    !!
    !---------------------------------------------------------------------------------------------------------
    subroutine add_equation(self,varstring)
        class(equation_set_t),  intent(inout)  :: self
        character(len=*),       intent(in)     :: varstring

        type(equation_t), allocatable    :: temp(:)
        integer(ik) :: ieq, ierr, ind
        logical     :: already_added


        !
        ! Check if equation was already added by another function
        !
        ind = self%prop%get_equation_index(varstring)
        already_added = (ind /= 0)


        !
        ! Add equation if necessary
        !
        if (.not. already_added) then


            !
            ! If there are already equations allocated, reallocate and add new equation
            !
            if (allocated(self%prop%eqns)) then

                ! Allocate temp eqn array with one extra slot for new eqn
                allocate(temp(size(self%prop%eqns) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current eqns to first temp slots
                do ieq = 1,size(self%prop%eqns)
                    temp(ieq) = self%prop%eqns(ieq)
                end do

                ! Add new eqn to last slot
                call temp(size(temp))%set_name(varstring)
                call temp(size(temp))%set_index(size(temp))


                ! Store temp equation array to equation properties
                self%prop%eqns = temp

            !
            ! If there are no equations allocated, allocate one slot and set data
            !
            else

                ! Allocate equation
                allocate(self%prop%eqns(1), stat=ierr)
                if (ierr /= 0) call AllocationError


                self%prop%eqns(1)%name = varstring
                self%prop%eqns(1)%ind  = 1  ! equation index is set to the index it was added at

            end if

        end if


    end subroutine add_equation
    !***************************************************************************************************************









    !>  Add a spatial operator to the equation set.
    !!
    !!  This accepts a string that is the name of an operator to add. This function then searched the operator
    !!  register for an operator that matches the incoming string. If one is found, it is created and added 
    !!  to the equation set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------------------------------
    subroutine add_operator(self,string)
        class(equation_set_t),  intent(inout)   :: self
        character(len=*),       intent(in)      :: string

        class(operator_t),          allocatable :: new_operator
        class(operator_wrapper_t),  allocatable :: temp(:)
        integer(ik)     :: ierr, iflux, operator_type, ieq


        !
        ! Create new operator
        !
        allocate(new_operator, source=build_operator(string), stat=ierr)
        if (ierr /= 0) call AllocationError


        !
        ! Get operator type
        !
        operator_type = new_operator%get_operator_type()

        
        !
        ! Add to correct operator array
        !
        if (operator_type == BOUNDARY_ADVECTIVE_FLUX) then



            ! Allocate temporary flux array with one additional slot
            if (allocated(self%boundary_advective_operator)) then

                ! Allocate
                allocate(temp(size(self%boundary_advective_operator) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current flux components to temp array
                do iflux = 1,size(self%boundary_advective_operator)
                    allocate(temp(iflux)%op,source=self%boundary_advective_operator(iflux)%op, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end do

            else
                ! Allocate new slot
                allocate(temp(1), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if





        else if (operator_type == BOUNDARY_DIFFUSIVE_FLUX) then

            ! Allocate temporary flux array with one additional slot
            if (allocated(self%boundary_diffusive_operator)) then

                ! Allocate
                allocate(temp(size(self%boundary_diffusive_operator) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current flux components to temp array
                do iflux = 1,size(self%boundary_diffusive_operator)
                    allocate(temp(iflux)%op,source=self%boundary_diffusive_operator(iflux)%op, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end do

            else
                ! Allocate new slot
                allocate(temp(1), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if






        else if (operator_type == VOLUME_ADVECTIVE_FLUX) then



            ! Allocate temporary flux array with one additional slot
            if (allocated(self%volume_advective_operator)) then

                ! Allocate
                allocate(temp(size(self%volume_advective_operator) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current flux components to temp array
                do iflux = 1,size(self%volume_advective_operator)
                    allocate(temp(iflux)%op,source=self%volume_advective_operator(iflux)%op, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end do

            else

                ! Allocate new slot
                allocate(temp(1), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if





        else if (operator_type == VOLUME_DIFFUSIVE_FLUX) then



            ! Allocate temporary flux array with one additional slot
            if (allocated(self%volume_diffusive_operator)) then

                ! Allocate
                allocate(temp(size(self%volume_diffusive_operator) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current flux components to temp array
                do iflux = 1,size(self%volume_diffusive_operator)
                    allocate(temp(iflux)%op,source=self%volume_diffusive_operator(iflux)%op, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end do

            else

                ! Allocate new slot
                allocate(temp(1), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if








        else if (operator_type == BC_FLUX) then


            ! Allocate temporary flux array with one additional slot
            if (allocated(self%bc_operator)) then

                ! Allocate
                allocate(temp(size(self%bc_operator) + 1), stat=ierr)
                if (ierr /= 0) call AllocationError

                ! Copy current flux components to temp array
                do iflux = 1,size(self%bc_operator)
                    allocate(temp(iflux)%op,source=self%bc_operator(iflux)%op, stat=ierr)
                    if (ierr /= 0) call AllocationError
                end do

            else

                ! Allocate new slot
                allocate(temp(1), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if




        else
            call chidg_signal_one(FATAL,"equation_set%add_operator: 'Operator type was not valid'", operator_type)
        end if





        !
        ! Assign new operator
        !
        allocate(temp(size(temp))%op, source=new_operator, stat=ierr)
        if (ierr /= 0) call AllocationError




        !
        ! Copy extended temp array to equation set storage
        !
        if (operator_type == BOUNDARY_ADVECTIVE_FLUX) then
            self%boundary_advective_operator = temp
            self%function_data%nboundary_advective_flux = size(self%boundary_advective_operator)


        else if (operator_type == BOUNDARY_DIFFUSIVE_FLUX) then
            self%boundary_diffusive_operator = temp
            self%function_data%nboundary_diffusive_flux = size(self%boundary_diffusive_operator)

        else if (operator_type == VOLUME_ADVECTIVE_FLUX) then
            self%volume_advective_operator = temp
            self%function_data%nvolume_advective_flux = size(self%volume_advective_operator)

        else if (operator_type == VOLUME_DIFFUSIVE_FLUX) then
            self%volume_diffusive_operator = temp
            self%function_data%nvolume_diffusive_flux = size(self%volume_diffusive_operator)

        else if (operator_type == BC_FLUX) then
            self%bc_operator = temp

        else
            call chidg_signal_one(FATAL,"equation_set%add_operator: 'Operator type was not valid'", operator_type)
        end if




        !
        ! Turn on equations for the new operator
        !
        do ieq = 1,size(new_operator%eqns)
            call self%add_equation(new_operator%eqns(ieq)%str)
        end do


    end subroutine add_operator
    !*************************************************************************************************************************













    !>  Loops through the attached boundary advective operator functions and computes them 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/15/2016
    !!
    !!
    !--------------------------------------------------------------------------------------------------------------
    subroutine compute_boundary_advective_operators(self,worker,idiff)
        class(equation_set_t),   intent(inout)   :: self
        type(chidg_worker_t),    intent(inout)   :: worker
        integer(ik),             intent(in)      :: idiff

        integer(ik)             :: nfcn, ifcn, idepend, ndepend
        logical                 :: interior_face, chimera_face, compute_face, compute_function, linearize_function

        associate( mesh => worker%mesh, &
                   idom => worker%element_info%idomain_l, ielem => worker%element_info%ielement_l, &
                   iface => worker%iface, prop => self%prop )


        !
        ! Only call the following routines for interior faces -- ftype == 0
        ! Furthermore, only call the routines if we are computing derivatives for the neighbor of
        ! iface or for the current element(DIAG). This saves a lot of unnecessary compute_boundary calls.
        !
        interior_face = ( mesh(idom)%faces(ielem,iface)%ftype == INTERIOR )
        chimera_face  = ( mesh(idom)%faces(ielem,iface)%ftype == CHIMERA )
        compute_face  = (interior_face .or. chimera_face) .and. ( (idiff == iface) .or. (idiff == DIAG) )

        if (compute_face) then

            !
            ! Get number of elements we are linearizing with respect to
            !
            ndepend = self%get_boundary_ndependent_elements(mesh,worker%face_info(),idiff)



            if (allocated(self%boundary_advective_operator)) then
                nfcn = size(self%boundary_advective_operator)
                do ifcn = 1,nfcn

                    worker%function_info%type   = BOUNDARY_ADVECTIVE_FLUX
                    worker%function_info%ifcn   = ifcn
                    worker%function_info%idiff  = idiff

                    compute_function   = worker%solverdata%function_status%compute_function(   worker%face_info(), worker%function_info )
                    linearize_function = worker%solverdata%function_status%linearize_function( worker%face_info(), worker%function_info )
                    

                    if ( compute_function .or. linearize_function ) then
                        !
                        ! Compute boundary flux once for each donor. 
                        !   - For interior faces ndepend == 1. 
                        !   - For Chimera faces ndepend is potentially > 1.
                        !
                        do idepend = 1,ndepend
                            worker%function_info%seed    = face_compute_seed(mesh,idom,ielem,iface,idepend,idiff)
                            worker%function_info%idepend = idepend

                            call self%boundary_advective_operator(ifcn)%op%compute(worker,prop)

                        end do
                    end if


                end do ! ifcn

            end if ! boundary_advective_flux loop



        end if !compute_face

        end associate

    end subroutine compute_boundary_advective_operators
    !*****************************************************************************************************************









    !>  Loops through the attached boundary diffusive operator functions and computes them 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/15/2016
    !!
    !!
    !--------------------------------------------------------------------------------------------------------------
    subroutine compute_boundary_diffusive_operators(self,worker,idiff)
        class(equation_set_t),   intent(inout)   :: self
        type(chidg_worker_t),   intent(inout)   :: worker
        integer(ik),            intent(in)      :: idiff

        integer(ik)             :: nfcn, ifcn, idepend, ndepend
        logical                 :: compute_function, linearize_function, interior_face, chimera_Face, compute_face

        associate( mesh => worker%mesh, &
                   idom => worker%element_info%idomain_l, ielem => worker%element_info%ielement_l, &
                   iface => worker%iface, prop => self%prop)

        !
        ! Only call the following routines for interior faces -- ftype == 0
        ! Furthermore, only call the routines if we are computing derivatives for the neighbor of
        ! iface or for the current element(DIAG). This saves a lot of unnecessary compute_boundary calls.
        !
        interior_face = ( mesh(idom)%faces(ielem,iface)%ftype == INTERIOR )
        chimera_face  = ( mesh(idom)%faces(ielem,iface)%ftype == CHIMERA )
        compute_face  = (interior_face .or. chimera_face) .and. ( (idiff == iface) .or. (idiff == DIAG) )

        if (compute_face) then

            !
            ! Get number of elements we are linearizing with respect to
            !
            ndepend = self%get_boundary_ndependent_elements(mesh,worker%face_info(),idiff)


            if (allocated(self%boundary_diffusive_operator)) then
                nfcn = size(self%boundary_diffusive_operator)
                do ifcn = 1,nfcn

                    worker%function_info%type   = BOUNDARY_DIFFUSIVE_FLUX
                    worker%function_info%ifcn   = ifcn
                    worker%function_info%idiff  = idiff

                    compute_function     = worker%solverdata%function_status%compute_function(   worker%face_info(), worker%function_info )
                    linearize_function   = worker%solverdata%function_status%linearize_function( worker%face_info(), worker%function_info )
                    

                    if ( compute_function .or. linearize_function ) then
                        !
                        ! Compute boundary flux once for each donor. 
                        !   - For interior faces ndepend == 1. 
                        !   - For Chimera faces ndepend is potentially > 1.
                        !
                        do idepend = 1,ndepend
                            worker%function_info%seed    = face_compute_seed(mesh,idom,ielem,iface,idepend,idiff)
                            worker%function_info%idepend = idepend

                            call self%boundary_diffusive_operator(ifcn)%op%compute(worker,prop)

                        end do
                    end if


                end do ! ifcn

            end if ! boundary_diffusive_flux loop



        end if ! compute_face

        end associate

    end subroutine compute_boundary_diffusive_operators
    !*****************************************************************************************************************













    !>  Loops through the attached volume advective operator functions and computes them 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/15/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------------------------------
    subroutine compute_volume_advective_operators(self,worker,idiff)
        class(equation_set_t),       intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        integer(ik),                intent(in)      :: idiff

        integer(ik)             :: nfcn, ifcn, idepend
        type(function_info_t)   :: function_info
        logical                 :: compute_flux

        associate( mesh => worker%mesh, elem_info => worker%element_info, &
                   idom => worker%element_info%idomain_l, ielem => worker%element_info%ielement_l, prop => self%prop)


        !
        ! Volume advective flux only depends on the interior element
        !
        idepend = 1


        compute_flux = ( (idiff == DIAG) .and. allocated(self%volume_advective_operator) )
        if (compute_flux) then
            nfcn = size(self%volume_advective_operator)
            do ifcn = 1,nfcn

                worker%function_info%type    = VOLUME_ADVECTIVE_FLUX
                worker%function_info%ifcn    = ifcn
                worker%function_info%idiff   = idiff
                worker%function_info%idepend = idepend
                worker%function_info%seed    = element_compute_seed(mesh,idom,ielem,idepend,idiff)

                call self%volume_advective_operator(ifcn)%op%compute(worker,prop)

            end do ! ifcn
        end if

        end associate


    end subroutine compute_volume_advective_operators
    !******************************************************************************************************************










    !>  Loops through the attached volume diffusive operator functions and computes them 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/16/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------------------------------
    subroutine compute_volume_diffusive_operators(self,worker,idiff)
        class(equation_set_t),       intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        integer(ik),                intent(in)      :: idiff

        integer(ik)             :: nfcn, ifcn, idepend, ndepend
        type(function_info_t)   :: function_info
        logical                 :: linearize_me, compute_function

        associate( mesh => worker%mesh, elem_info => worker%element_info, &
                   idom => worker%element_info%idomain_l, ielem => worker%element_info%ielement_l, prop => self%prop)


        !
        ! Get number of elements we are linearizing with respect to
        !
        ndepend = self%get_volume_ndependent_elements(mesh,elem_info,idiff)



        linearize_me = (idiff == DIAG)
        if (linearize_me) then
            compute_function = .true.
        else
            compute_function = ( (mesh(elem_info%idomain_l)%faces(elem_info%ielement_l,idiff)%ftype == INTERIOR) .or. &
                                 (mesh(elem_info%idomain_l)%faces(elem_info%ielement_l,idiff)%ftype == CHIMERA) )
        end if
                            


        if (compute_function) then

            if (allocated(self%volume_diffusive_operator)) then
                nfcn = size(self%volume_diffusive_operator)
                do ifcn = 1,nfcn
    
                    !
                    ! Compute boundary flux once for each donor. 
                    !   - For interior faces ndepend == 1. 
                    !   - For Chimera faces ndepend is potentially > 1.
                    !
                    do idepend = 1,ndepend
    
                        worker%function_info%type    = VOLUME_DIFFUSIVE_FLUX
                        worker%function_info%ifcn    = ifcn
                        worker%function_info%idiff   = idiff
                        worker%function_info%idepend = idepend
                        worker%function_info%seed    = element_compute_seed(mesh,idom,ielem,idepend,idiff)
    
                        call self%volume_diffusive_operator(ifcn)%op%compute(worker,prop)
    
                    end do
    
                end do ! ifcn
            end if

        end if
        end associate


    end subroutine compute_volume_diffusive_operators
    !******************************************************************************************************************













    !>  Loops through the attached boundary advective operator functions and computes them 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/15/2016
    !!
    !!
    !--------------------------------------------------------------------------------------------------------------
    subroutine compute_bc_operators(self,worker,bcset,idiff)
        class(equation_set_t),      intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(bcset_t),              intent(inout)   :: bcset(:)
        integer(ik),                intent(in)      :: idiff

        integer(ik)             :: nfcn, ifcn, idepend, ndepend, BC_ID, BC_face, ielement_c
        logical                 :: interior_face, chimera_face, boundary_face, compute_face, &
                                   compute_function, linearize_function

        associate( mesh => worker%mesh, &
                   idom => worker%element_info%idomain_l, ielem => worker%element_info%ielement_l, &
                   iface => worker%iface, prop => self%prop )


        !
        ! Only call the following routines for interior faces -- ftype == 0
        ! Furthermore, only call the routines if we are computing derivatives for the neighbor of
        ! iface or for the current element(DIAG). This saves a lot of unnecessary compute_boundary calls.
        !
        boundary_face = (mesh(idom)%faces(ielem,iface)%ftype == BOUNDARY)
        !compute_face  = (boundary_face) .and. ( (idiff == iface) .or. (idiff == DIAG) )
        compute_face  = (boundary_face) .and. ( (idiff == DIAG) )

        if (compute_face) then

            !
            ! Get number of elements we are linearizing with respect to
            !
            ndepend = self%get_boundary_ndependent_elements(mesh,worker%face_info(),idiff)


            !
            ! Get index of boundary condition. Get index in bc_patch that corresponds to current face.
            !
            BC_ID   = mesh(idom)%faces(ielem,iface)%BC_ID
            BC_face = mesh(idom)%faces(ielem,iface)%BC_face


            if (allocated(self%bc_operator)) then
                nfcn = size(self%bc_operator)
                do ifcn = 1,nfcn

                    worker%function_info%type   = BC_FLUX
                    worker%function_info%ifcn   = ifcn
                    worker%function_info%idiff  = idiff

                    !
                    ! Compute boundary flux once for each donor. 
                    !   - For interior faces ndepend == 1. 
                    !   - For Chimera faces ndepend is potentially > 1.
                    !   - For BC faces ndepend is potentially > 1.
                    !
                    do idepend = 1,ndepend


                        !
                        ! Get coupled element to linearize against.
                        !
                        ielement_c = bcset(idom)%bcs(BC_ID)%bc_patch%coupled_elements(BC_face)%at(idepend)
                        worker%function_info%seed%idomain_g  = mesh(idom)%elems(ielement_c)%idomain_g
                        worker%function_info%seed%idomain_l  = mesh(idom)%elems(ielement_c)%idomain_l
                        worker%function_info%seed%ielement_g = mesh(idom)%elems(ielement_c)%ielement_g
                        worker%function_info%seed%ielement_l = mesh(idom)%elems(ielement_c)%ielement_l
                        worker%function_info%seed%iproc      = IRANK
                        worker%function_info%idepend         = idepend

                        call self%bc_operator(ifcn)%op%compute(worker,prop)

                    end do


                end do ! ifcn

            end if ! boundary_advective_flux loop



        end if !compute_face

        end associate

    end subroutine compute_bc_operators
    !*****************************************************************************************************************






















    !>  Return the number of elements that a boundary function depends on in the linearization direction 'idiff'.
    !!
    !!  Often, this may be just 1. Because a flux linearized wrt its owner element just has 1 dependent element; itself.
    !!  A flux linearized wrt its neighbor element has just 1 dependent element; it's neighbor. If however, a face
    !!  is a Chimera face, then when linearized with respect to its donors, ndepend will be equal to the number of
    !!  donor elements that are providing information to that face.
    !!
    !!  @author Nathan A. Wukie(AFRL)
    !!  @date   8/15/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------------------------------
    function get_boundary_ndependent_elements(self,mesh,face_info,idiff) result(ndepend)
        class(equation_set_t),   intent(in)   :: self
        type(mesh_t),           intent(in)   :: mesh(:)
        type(face_info_t),      intent(in)   :: face_info
        integer(ik),            intent(in)   :: idiff

        integer(ik) :: ChiID, ndepend
        logical     :: depend_me, depend_neighbor, chimera_face, bc_face

        associate( idom => face_info%idomain_l, ielem => face_info%ielement_l, iface => face_info%iface )

        depend_me       = (idiff == DIAG)
        depend_neighbor = (idiff == XI_MIN   .or. idiff == XI_MAX  .or. &
                           idiff == ETA_MIN  .or. idiff == ETA_MAX .or. &
                           idiff == ZETA_MIN .or. idiff == ZETA_MAX)


        if (depend_me) then

            ndepend = 1



        else if (depend_neighbor) then

            chimera_face  = ( mesh(idom)%faces(ielem,iface)%ftype == CHIMERA )
            bc_face       = ( mesh(idom)%faces(ielem,iface)%ftype == BOUNDARY)

            if ( chimera_face ) then
                ChiID  = mesh(idom)%faces(ielem,iface)%ChiID
                ndepend = mesh(idom)%chimera%recv%data(ChiID)%ndonors()

            else if ( bc_face ) then
                ndepend = mesh(idom)%faces(ielem,iface)%BC_ndepend

            else
                ! Standard conforming neighbor, only one dependent element.
                ndepend = 1
            end if

        end if


        end associate

    end function get_boundary_ndependent_elements
    !*****************************************************************************************************************





    !>  Return the number of elements that a volume function depends on in the linearization direction 'idiff'.
    !!
    !!  Often, this may be just 1. Because a flux linearized wrt its owner element just has 1 dependent element; itself.
    !!  A flux linearized wrt its neighbor element has just 1 dependent element; it's neighbor. If however, a face
    !!  is a Chimera face, then when linearized with respect to its donors, ndepend will be equal to the number of
    !!  donor elements that are providing information to that face.
    !!
    !!  @author Nathan A. Wukie(AFRL)
    !!  @date   8/16/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------------------------------
    function get_volume_ndependent_elements(self,mesh,elem_info,idiff) result(ndepend)
        class(equation_set_t),   intent(in)   :: self
        type(mesh_t),           intent(in)   :: mesh(:)
        type(element_info_t),   intent(in)   :: elem_info
        integer(ik),            intent(in)   :: idiff

        integer(ik) :: ChiID, ndepend, iface
        logical     :: depend_me, depend_neighbor, chimera_face

        associate( idom => elem_info%idomain_l, ielem => elem_info%ielement_l )


        depend_me       = (idiff == DIAG)
        depend_neighbor = (idiff == XI_MIN   .or. idiff == XI_MAX  .or. &
                           idiff == ETA_MIN  .or. idiff == ETA_MAX .or. &
                           idiff == ZETA_MIN .or. idiff == ZETA_MAX)


        if (depend_me) then

            ndepend = 1



        else if (depend_neighbor) then
            ! Search iface in the direction of linearization
            iface = idiff

            chimera_face  = ( mesh(idom)%faces(ielem,iface)%ftype == CHIMERA )

            if ( chimera_face ) then
                ! only need to compute multiple times when we need the linearization of the chimera neighbors
                ChiID  = mesh(idom)%faces(ielem,iface)%ChiID
                ndepend = mesh(idom)%chimera%recv%data(ChiID)%ndonors()
            else
                ! Standard conforming neighbor, only one dependent element.
                ndepend = 1
            end if

        end if


        end associate

    end function get_volume_ndependent_elements
    !*****************************************************************************************************************


end module type_equation_set