module type_cache_handler
#include <messenger.h>
    use mod_kinds,          only: rk, ik
    use mod_constants,      only: NFACES, INTERIOR, CHIMERA, BOUNDARY, DIAG, NO_PROC,   &
                                  ME, NEIGHBOR, ZERO, HALF, ONE,                        &
                                  XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX, &
                                  NO_ID, dQ_DIFF, dBC_DIFF, dX_DIFF, dD_DIFF, NO_DIFF,  &
                                  AUXILIARY, PRIMARY
    use mod_DNAD_tools,     only: face_compute_seed, element_compute_seed
    use mod_interpolate,    only: interpolate_face_autodiff, interpolate_element_autodiff
    use mod_chidg_mpi,      only: IRANK
    use mod_io,             only: verbosity
    use DNAD_D

    use type_chidg_cache,       only: chidg_cache_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_equation_set,      only: equation_set_t
    use type_bc_state_group,    only: bc_state_group_t
    use type_svector,           only: svector_t
    use type_timer,             only: timer_t
    implicit none



    !>  An object for handling cache operations. Particularly, updating the cache contents.
    !!
    !!  The problem solved here is this. The cache is used in operator_t's to pull data
    !!  computed at quadrature nodes. The cache also requires bc_operators's to precompute
    !!  the boundary condition solution as an external state and also to compute the BR2
    !!  diffusion lifting operators. This introduced a pesky circular dependency.
    !!
    !!  The problem was solved by introducing this cache_handler object. This separates the
    !!  cache behavior from the cache storage. The operator_t's need the cache storage. 
    !!  They don't need to know how the data got there.
    !!
    !!  So this higher-level interface sits outside of the hierarchy that caused the circular
    !!  dependency to handle the cache behavior, such as how it gets updated.
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    type, public :: cache_handler_t

        type(timer_t)   :: timer_primary, timer_model, timer_lift, timer_resize, timer_model_grad_compute, timer_interpolate, timer_gradient, timer_ale

    contains

        procedure   :: update   ! Resize/Update the cache fields

        procedure, private  :: update_auxiliary_fields
        procedure, private  :: update_primary_fields
        procedure, private  :: update_adjoint_fields

        procedure, private  :: update_auxiliary_interior
        procedure, private  :: update_auxiliary_exterior
        procedure, private  :: update_auxiliary_element
        procedure, private  :: update_auxiliary_bc

        procedure, private  :: update_primary_interior
        procedure, private  :: update_primary_exterior
        procedure, private  :: update_primary_element
        procedure, private  :: update_primary_bc
        procedure, private  :: update_primary_lift

        procedure, private  :: update_model_interior
        procedure, private  :: update_model_exterior
        procedure, private  :: update_model_element
        procedure, private  :: update_model_bc

        procedure, private  :: update_adjoint_element
        procedure, private  :: update_adjoint_interior

        procedure, private  :: update_lift_faces_internal
        procedure, private  :: update_lift_faces_external

    end type cache_handler_t
    !****************************************************************************************





contains


    !>  Resize chidg_cache in worker, update cache components.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update(self,worker,equation_set,bc_state_group,components,face,differentiate,bc_parameters,lift)
        class(cache_handler_t),     intent(inout)           :: self
        type(chidg_worker_t),       intent(inout)           :: worker
        type(equation_set_t),       intent(inout)           :: equation_set(:)
        type(bc_state_group_t),     intent(inout)           :: bc_state_group(:)
        character(*),               intent(in)              :: components
        integer(ik),                intent(in)              :: face
        integer(ik),                intent(in)              :: differentiate
        type(svector_t),            intent(in), optional    :: bc_parameters
        logical,                    intent(in)              :: lift

        integer(ik) :: idomain_l, ielement_l, iface, eqn_ID, face_min, face_max
        logical     :: compute_gradients, valid_indices, update_interior_faces, update_exterior_faces, update_element

        type(AD_D), allocatable, dimension(:) :: grad1_mom3, grad2_mom3, grad3_mom3

        ! Check for valid indices
        valid_indices = (worker%element_info%idomain_l /= 0) .and. &
                        (worker%element_info%ielement_l /= 0) .and. &
                        (worker%itime /= 0)

        if (.not. valid_indices) call chidg_signal(FATAL,"cache_handler%update: Bad domain/element/time indices were detected during update.")

        ! Store lift indicator in worker
        worker%contains_lift = lift

        ! Check for valid components
        select case(trim(components))
            case('all')
                update_interior_faces = .true.
                update_exterior_faces = .true.
                update_element        = .true.
            case('element')
                update_interior_faces = .false.
                update_exterior_faces = .false.
                update_element        = .true.
            case('faces')
                update_interior_faces = .true.
                update_exterior_faces = .true.
                update_element        = .false.
            case('interior faces')
                update_interior_faces = .true.
                update_exterior_faces = .false.
                update_element        = .false.
            case('exterior faces')
                update_interior_faces = .false.
                update_exterior_faces = .true.
                update_element        = .false.
            case default
                call chidg_signal_one(FATAL,"cache_handler%update: Bad 'components' argument.",trim(components))
        end select


        ! Set range of faces to update
        if (face == NO_ID) then
            face_min = 1        ! Update all faces
            face_max = NFACES
        else
            face_min = face     ! Only update one face
            face_max = face
        end if


        ! Resize cache
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        call self%timer_resize%start()
        call worker%cache%resize(worker%mesh,worker%prop,idomain_l,ielement_l,differentiate,lift)
        call self%timer_resize%stop()


        ! Determine if we want to update gradient terms in the cache
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        compute_gradients = (allocated(equation_set(eqn_ID)%volume_diffusive_operator)   .or. &
                             allocated(equation_set(eqn_ID)%boundary_diffusive_operator) )

        ! Update fields
        call self%timer_primary%start()
        call self%update_auxiliary_fields(worker,equation_set,bc_state_group,differentiate)
        call self%update_primary_fields(  worker,equation_set,bc_state_group,differentiate,compute_gradients,update_element,update_interior_faces,update_exterior_faces,face_min,face_max)
        call self%update_adjoint_fields(  worker,equation_set,bc_state_group,differentiate,compute_gradients,update_element,update_interior_faces,update_exterior_faces,face_min,face_max)
        call self%timer_primary%stop()


        call self%timer_model%start()
        if (update_element) call self%update_model_element(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-)')
        call self%timer_model%stop()


        ! Compute f(Q-) models. Interior, Exterior, BC, Element
        call self%timer_model%start()
        do iface = face_min,face_max

            ! Update worker face index
            call worker%set_face(iface)

            ! Update face interior/exterior/bc states.
            if (update_interior_faces) call self%update_model_interior(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-)')
            if (update_exterior_faces) call self%update_model_exterior(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-)')

        end do !iface
        call self%timer_model%stop()



        ! Compute f(Q-) models. Interior, Exterior, BC, Element
        call self%timer_model%start()
        do iface = face_min,face_max

            ! Update worker face index
            call worker%set_face(iface)

            if (update_exterior_faces) call self%update_primary_bc(worker,equation_set,bc_state_group,differentiate,bc_parameters)
            if (update_exterior_faces) call self%update_model_bc(  worker,equation_set,bc_state_group,differentiate,model_type='f(Q-)')

            if (update_interior_faces) call self%update_model_interior(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-,Q+)')
            if (update_exterior_faces) call self%update_model_exterior(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-,Q+)')
            if (update_exterior_faces) call self%update_model_bc(      worker,equation_set,bc_state_group,differentiate,model_type='f(Q-,Q+)')


        end do !iface
        call self%timer_model%stop()


        call self%timer_model%start()
        if (update_element) call self%update_model_element(worker,equation_set,bc_state_group,differentiate,model_type='f(Q-,Q+)')
        call self%timer_model%stop()



        ! Compute f(Q-,Q+), f(Grad(Q) models. Interior, Exterior, BC, Element
        call self%timer_gradient%start()
        if (compute_gradients) then

            ! Update lifting operators for second-order pde's
            call self%timer_lift%start()
            if (lift) call self%update_primary_lift(worker,equation_set,bc_state_group,differentiate)
            call self%timer_lift%stop()

            ! Loop through faces and cache 'internal', 'external' interpolated states
            do iface = face_min,face_max

                ! Update worker face index
                call worker%set_face(iface)

                ! Update face interior/exterior/bc states.
                if (update_interior_faces) call self%update_model_interior(worker,equation_set,bc_state_group,differentiate,model_type='f(Grad(Q))')
                if (update_exterior_faces) call self%update_model_exterior(worker,equation_set,bc_state_group,differentiate,model_type='f(Grad(Q))')
                if (update_exterior_faces) call self%update_model_bc(      worker,equation_set,bc_state_group,differentiate,model_type='f(Grad(Q))')

            end do !iface

            ! Update model 'element' cache entries
            if (update_element) call self%update_model_element(worker,equation_set,bc_state_group,differentiate,model_type='f(Grad(Q))')

        end if ! compute_gradients
        call self%timer_gradient%stop()


    end subroutine update
    !****************************************************************************************







    !>  Update the cache entries for the primary fields.
    !!
    !!  Activities:
    !!      #1: Loop through faces, update 'face interior', 'face exterior' caches for 
    !!          'value' and 'gradients'
    !!      #2: Update the 'element' cache for 'value' and 'gradients'
    !!      #3: Update the lifting operators for all cache components
    !!          (interior, exterior, element)
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_fields(self,worker,equation_set,bc_state_group,differentiate,compute_gradients,update_element, update_interior_faces, update_exterior_faces, face_min, face_max)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients
        logical,                    intent(in)      :: update_element
        logical,                    intent(in)      :: update_interior_faces
        logical,                    intent(in)      :: update_exterior_faces
        integer(ik),                intent(in)      :: face_min
        integer(ik),                intent(in)      :: face_max

        integer(ik)                                 :: idomain_l, ielement_l, iface, &
                                                       idepend, ieqn, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Loop through faces and cache 'internal', 'external' interpolated states
        do iface = face_min,face_max

            ! Update worker face index
            call worker%set_face(iface)

            ! Update face interior/exterior/bc states.
            if (update_interior_faces) call self%update_primary_interior(worker,equation_set,bc_state_group,differentiate,compute_gradients)
            if (update_exterior_faces) call self%update_primary_exterior(worker,equation_set,bc_state_group,differentiate,compute_gradients)

        end do !iface

        ! Update 'element' cache
        if (update_element) call self%update_primary_element(worker,equation_set,bc_state_group,differentiate,compute_gradients)

    end subroutine update_primary_fields
    !****************************************************************************************





    !>  Update the cache entries for the adjoint fields.
    !!
    !!  Activities:
    !!      #1: Loop through faces, update 'face interior' caches for 
    !!          'value' and 'gradients'
    !!      #2: Update the 'element' cache for 'value' 
    !!
    !!  NOTE: this is only for post-processing. Therefore, we are not interesed in computing
    !!  exterior faces
    !!
    !!  @author Matteo Ugolotti
    !!  @date   10/3/2017
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_adjoint_fields(self,worker,equation_set,bc_state_group,differentiate,compute_gradients,update_element, update_interior_faces, update_exterior_faces, face_min, face_max)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients
        logical,                    intent(in)      :: update_element
        logical,                    intent(in)      :: update_interior_faces
        logical,                    intent(in)      :: update_exterior_faces
        integer(ik),                intent(in)      :: face_min
        integer(ik),                intent(in)      :: face_max

        integer(ik)                                 :: idomain_l, ielement_l, iface, &
                                                       idepend, ieqn, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Loop through faces and cache 'internal', 'external' interpolated states
        do iface = face_min,face_max

            ! Update worker face index
            call worker%set_face(iface)

            ! Update face interior/exterior/bc states.
            if (update_interior_faces) call self%update_adjoint_interior(worker,equation_set,differentiate)
            
            !No need to update exterior faces for adjoint variables
            !if (update_exterior_faces) call self%update_adjoint_exterior(worker,equation_set,bc_state_group,differentiate,compute_gradients)

        end do !iface

        ! Update 'element' cache
        if (update_element) call self%update_adjoint_element(worker,equation_set,differentiate)

    end subroutine update_adjoint_fields
    !****************************************************************************************




    !>  Update the cache entries for the auxiliary fields.
    !!
    !!  Activities:
    !!      #1: Loop through faces, update 'face interior', 'face exterior' caches for 
    !!          'value' and 'gradients'
    !!      #2: Update the 'element' cache for 'value' and 'gradients'
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_fields(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idomain_l, ielement_l, iface, idepend, &
                                                       ieqn, ifield, iaux_field, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Loop through faces and cache internal, external interpolated states
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)

            ! Update face interior/exterior states.
            call self%update_auxiliary_interior(worker,equation_set,bc_state_group,differentiate)
            call self%update_auxiliary_exterior(worker,equation_set,bc_state_group,differentiate)
            call self%update_auxiliary_bc(      worker,equation_set,bc_state_group,differentiate)

        end do !iface

        ! Update cache 'element' data
        call self%update_auxiliary_element(worker,equation_set,bc_state_group,differentiate)

    end subroutine update_auxiliary_fields
    !****************************************************************************************








    !>  Update the primary field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_element(self,worker,equation_set,bc_state_group,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ifield, idomain_l, ielement_l, &
                                                       iface, idiff, eqn_ID
        character(:),   allocatable                 :: field
        real(rk),       allocatable                 :: ale_Dinv(:,:,:)
        real(rk),       allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        type(AD_D),     allocatable, dimension(:)   :: value_u, grad1_u, grad2_u, grad3_u, grad1_tmp, grad2_tmp, grad3_tmp


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        ! Element primary fields volume 'value' cache. Only depends on interior element
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if

        ! Element primary fields volume 'value' cache. Only depends on interior element
        if (differentiate == dQ_DIFF .or. &
            differentiate == dX_DIFF .or. &
            differentiate == dBC_DIFF .or. &
            differentiate == dD_DIFF) then
            idiff = DIAG
        else if (differentiate == NO_DIFF) then
            idiff = 0
        end if



        ! Compute Value/Gradients
        idepend = 1
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff,worker%itime)
        worker%function_info%idepend = idepend
        worker%function_info%type    = PRIMARY 
        worker%function_info%dtype   = differentiate
        do ifield = 1,worker%mesh%domain(idomain_l)%nfields

            field = worker%prop(eqn_ID)%get_primary_field_name(ifield)

            ! Interpolate modes to nodes on undeformed element
            call self%timer_interpolate%start()
            value_u = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ifield,worker%itime,'value')
            call self%timer_interpolate%stop()

            ! Get ALE transformation data
            ale_g = worker%get_det_jacobian_grid_element('value')

            ! Compute transformation to deformed element
            value_u = (value_u/ale_g)

            ! Store quantities valid on the deformed element
            call worker%cache%set_data(field,'element',value_u,'value',0,worker%function_info%seed)



            ! Interpolate Grad(U)
            if (compute_gradients) then
                call self%timer_interpolate%start()
                ! Interpolate modes to nodes on undeformed element
                grad1_u = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ifield,worker%itime,'grad1')
                grad2_u = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ifield,worker%itime,'grad2')
                grad3_u = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ifield,worker%itime,'grad3')
                call self%timer_interpolate%stop()

                ! Get ALE transformation data
                ale_g_grad1 = worker%get_det_jacobian_grid_element('grad1')
                ale_g_grad2 = worker%get_det_jacobian_grid_element('grad2')
                ale_g_grad3 = worker%get_det_jacobian_grid_element('grad3')
                ale_Dinv    = worker%get_inv_jacobian_grid_element()

                ! Compute transformation to deformed element
                grad1_tmp = grad1_u-(value_u)*ale_g_grad1
                grad2_tmp = grad2_u-(value_u)*ale_g_grad2
                grad3_tmp = grad3_u-(value_u)*ale_g_grad3

                grad1_u = (ale_Dinv(1,1,:)*grad1_tmp + ale_Dinv(2,1,:)*grad2_tmp + ale_Dinv(3,1,:)*grad3_tmp)/ale_g
                grad2_u = (ale_Dinv(1,2,:)*grad1_tmp + ale_Dinv(2,2,:)*grad2_tmp + ale_Dinv(3,2,:)*grad3_tmp)/ale_g
                grad3_u = (ale_Dinv(1,3,:)*grad1_tmp + ale_Dinv(2,3,:)*grad2_tmp + ale_Dinv(3,3,:)*grad3_tmp)/ale_g

                ! Store quantities valid on the deformed element
                call worker%cache%set_data(field,'element',grad1_u,'gradient',1,worker%function_info%seed)
                call worker%cache%set_data(field,'element',grad2_u,'gradient',2,worker%function_info%seed)
                call worker%cache%set_data(field,'element',grad3_u,'gradient',3,worker%function_info%seed)

            end if

        end do !ifield


    end subroutine update_primary_element
    !*****************************************************************************************










    !>  Update the primary field 'face interior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_interior(self,worker,equation_set,bc_state_group,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ifield, idomain_l, ielement_l, iface, idiff, eqn_ID
        character(:),   allocatable                 :: field
        real(rk),       allocatable                 :: ale_Dinv(:,:,:)
        real(rk),       allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        type(AD_D),     allocatable, dimension(:)   :: value_u, grad1_u, grad2_u, grad3_u, grad1_tmp, grad2_tmp, grad3_tmp


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface

        ! Face interior state. 'values' only depends on interior element.
        idepend = 1


!        ! Set differentiation indicator
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if

        ! Set differentiation indicator
        !
        ! NB: the distance field differentiation needs the derivatives to be allocated 
        if (differentiate == dQ_DIFF .or. &
            differentiate == dX_DIFF .or. &
            differentiate == dBC_DIFF .or. &
            differentiate == dD_DIFF) then
            idiff = DIAG
        else if (differentiate == NO_DIFF) then
            idiff = 0
        end if


        ! Compute Values
        worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
        worker%function_info%idepend = idepend
        worker%function_info%idiff   = idiff
        worker%function_info%type    = PRIMARY 
        worker%function_info%dtype   = differentiate
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        do ifield = 1,worker%mesh%domain(idomain_l)%nfields

            field = worker%prop(eqn_ID)%get_primary_field_name(ifield)

            
            ! Interpolate modes to nodes on undeformed element
            ! NOTE: we always need to compute the graduent for interior faces for boundary conditions.
            call self%timer_interpolate%start()
            value_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'value',ME)
            grad1_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad1',ME)
            grad2_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad2',ME)
            grad3_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad3',ME)
            call self%timer_interpolate%stop()


            ! Get ALE transformation data
            ale_g       = worker%get_det_jacobian_grid_face('value','face interior')
            ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1','face interior')
            ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2','face interior')
            ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3','face interior')
            ale_Dinv    = worker%get_inv_jacobian_grid_face('face interior')


            ! Compute transformation to deformed element
            value_u   = value_u/ale_g
            grad1_tmp = grad1_u-(value_u)*ale_g_grad1
            grad2_tmp = grad2_u-(value_u)*ale_g_grad2
            grad3_tmp = grad3_u-(value_u)*ale_g_grad3

            grad1_u = (ale_Dinv(1,1,:)*grad1_tmp + ale_Dinv(2,1,:)*grad2_tmp + ale_Dinv(3,1,:)*grad3_tmp)/ale_g
            grad2_u = (ale_Dinv(1,2,:)*grad1_tmp + ale_Dinv(2,2,:)*grad2_tmp + ale_Dinv(3,2,:)*grad3_tmp)/ale_g
            grad3_u = (ale_Dinv(1,3,:)*grad1_tmp + ale_Dinv(2,3,:)*grad2_tmp + ale_Dinv(3,3,:)*grad3_tmp)/ale_g


            ! Store quantities valid on the deformed element
            call worker%cache%set_data(field,'face interior',value_u,'value',   0,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad1_u,'gradient',1,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad2_u,'gradient',2,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad3_u,'gradient',3,worker%function_info%seed,iface)

        end do !ifield


    end subroutine update_primary_interior
    !*****************************************************************************************










    !>  Update the primary field 'face exterior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_exterior(self,worker,equation_set,bc_state_group,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ifield, idomain_l, ielement_l, &
                                                       iface, BC_ID, BC_face, ndepend, idiff, eqn_ID, ChiID
        character(:),   allocatable                 :: field
        real(rk),       allocatable                 :: ale_Dinv(:,:,:)
        real(rk),       allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        type(AD_D),     allocatable, dimension(:)   :: value_u, grad1_u, grad2_u, grad3_u, grad1_tmp, grad2_tmp, grad3_tmp


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        ! Set differentiation indicator
!        if (differentiate) then
!            idiff = iface
!        else
!            idiff = 0
!        end if
!          
!        ! Compute the number of exterior element dependencies for face exterior state
!        ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)


        ! Set differentiation indicator
        ! NB: the distance field differentiation needs the derivatives to be allocated 
        if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF) then
            idiff = iface
            ! Compute the number of exterior element dependencies for face exterior state
            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
        else if (differentiate == dD_DIFF) then
            idiff = iface
            ! No need to loop over all dependent exteriors since derivatives are zero.
            ndepend = 1
        else 
            idiff = 0
            ! No need to loop over all dependent exteriors since derivatives are not needed.
            ndepend = 1
        end if




        ! Face exterior state. Value
        if ( (worker%face_type() == INTERIOR) .or. &
             (worker%face_type() == CHIMERA ) ) then
            

            if (worker%face_type() == INTERIOR) then
                eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
            else if (worker%face_type() == CHIMERA) then
                ChiID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ChiID
                eqn_ID = worker%mesh%domain(idomain_l)%chimera%recv(ChiID)%donor(1)%elem_info%eqn_ID
            end if


            do ifield = 1,worker%prop(eqn_ID)%nprimary_fields()
                field = worker%prop(eqn_ID)%get_primary_field_name(ifield)
                do idepend = 1,ndepend

                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%type    = PRIMARY 
                    worker%function_info%dtype   = differentiate


                    ! Interpolate modes to nodes on undeformed element
                call self%timer_interpolate%start()
                    value_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'value',NEIGHBOR)
                call self%timer_interpolate%stop()
                    ! Get ALE transformation data
                    ale_g = worker%get_det_jacobian_grid_face('value','face exterior')

                    ! Compute transformation to deformed element
                    value_u = (value_u/ale_g)

                    ! Store quantities valid on the deformed element
                    call worker%cache%set_data(field,'face exterior',value_u,'value',0,worker%function_info%seed,iface)



                    ! Interpolate Grad(U)
                    if (compute_gradients) then
                call self%timer_interpolate%start()
                        ! Interpolate modes to nodes on undeformed element
                        grad1_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad1',NEIGHBOR)
                        grad2_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad2',NEIGHBOR)
                        grad3_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad3',NEIGHBOR)
                call self%timer_interpolate%stop()


                        ! Get ALE transformation data
                        ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1','face exterior')
                        ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2','face exterior')
                        ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3','face exterior')
                        ale_Dinv    = worker%get_inv_jacobian_grid_face('face exterior')

                        
                        ! Compute transformation to deformed element
                        grad1_tmp = grad1_u-(value_u)*ale_g_grad1
                        grad2_tmp = grad2_u-(value_u)*ale_g_grad2
                        grad3_tmp = grad3_u-(value_u)*ale_g_grad3

                        grad1_u = (ale_Dinv(1,1,:)*grad1_tmp + ale_Dinv(2,1,:)*grad2_tmp + ale_Dinv(3,1,:)*grad3_tmp)/ale_g
                        grad2_u = (ale_Dinv(1,2,:)*grad1_tmp + ale_Dinv(2,2,:)*grad2_tmp + ale_Dinv(3,2,:)*grad3_tmp)/ale_g
                        grad3_u = (ale_Dinv(1,3,:)*grad1_tmp + ale_Dinv(2,3,:)*grad2_tmp + ale_Dinv(3,3,:)*grad3_tmp)/ale_g


                        ! Store quantities valid on the deformed element
                        call worker%cache%set_data(field,'face exterior',grad1_u,'gradient',1,worker%function_info%seed,iface)
                        call worker%cache%set_data(field,'face exterior',grad2_u,'gradient',2,worker%function_info%seed,iface)
                        call worker%cache%set_data(field,'face exterior',grad3_u,'gradient',3,worker%function_info%seed,iface)
                    end if


                end do !idepend
            end do !ifield

        end if


    end subroutine update_primary_exterior
    !*****************************************************************************************








    !>  Update the primary field BOUNDARY state functions. These are placed in the 
    !!  'face exterior' cache entry.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_bc(self,worker,equation_set,bc_state_group,differentiate,bc_parameters)
        class(cache_handler_t),     intent(inout)           :: self
        type(chidg_worker_t),       intent(inout)           :: worker
        type(equation_set_t),       intent(inout)           :: equation_set(:)
        type(bc_state_group_t),     intent(inout)           :: bc_state_group(:)
        integer(ik),                intent(in)              :: differentiate
        type(svector_t),            intent(in), optional    :: bc_parameters

        integer(ik)                 :: idepend, idomain_l, ielement_l, iface, ndepend, &
                                       istate, bc_ID, group_ID, patch_ID, face_ID, eqn_ID, itime_start, itime_end, itime_couple
        character(:),   allocatable :: field


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Face bc(exterior) state
        !
        if ( (worker%face_type() == BOUNDARY)  ) then
            
            bc_ID    = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%bc_ID
            group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
            patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
            face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID

            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)


            if ( worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%temporal_coupling == 'Global') then
                itime_start = 1
                itime_end   = worker%time_manager%ntime
            else
                itime_start = worker%itime
                itime_end   = worker%itime
            end if

            do istate = 1,size(bc_state_group(bc_ID)%bc_state)
                do idepend = 1,ndepend
                    do itime_couple = itime_start,itime_end

                        ! Get coupled bc element to linearize against.
                        !if (differentiate) then
                        if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dD_DIFF) then
                            worker%function_info%seed%idomain_g  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g(idepend)
                            worker%function_info%seed%idomain_l  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l(idepend)
                            worker%function_info%seed%ielement_g = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(idepend)
                            worker%function_info%seed%ielement_l = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(idepend)
                            worker%function_info%seed%iproc      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%proc(idepend)
                            worker%function_info%seed%itime      = itime_couple
                            worker%function_info%dtype           = differentiate 
                        else if (differentiate == dBC_DIFF) then
                            worker%function_info%seed%idomain_g  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g(idepend)
                            worker%function_info%seed%idomain_l  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l(idepend)
                            worker%function_info%seed%ielement_g = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(idepend)
                            worker%function_info%seed%ielement_l = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(idepend)
                            worker%function_info%seed%iproc      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%proc(idepend)
                            worker%function_info%seed%itime      = itime_couple
                            worker%function_info%dtype           = differentiate 
                            worker%function_info%bc_group_match  = (bc_parameters%data_(1)%get() == worker%mesh%bc_patch_group(group_ID)%name .or. bc_parameters%data_(1)%get() == '*')
                            worker%function_info%bc_param        = bc_parameters%data_(2)%get()
                        else
                            worker%function_info%seed%idomain_g  = 0
                            worker%function_info%seed%idomain_l  = 0
                            worker%function_info%seed%ielement_g = 0
                            worker%function_info%seed%ielement_l = 0
                            worker%function_info%seed%iproc      = NO_PROC
                            worker%function_info%seed%itime      = itime_couple
                            worker%function_info%dtype           = differentiate 
                        end if

                        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
                        call bc_state_group(bc_ID)%bc_state(istate)%state%compute_bc_state(worker,equation_set(eqn_ID)%prop, bc_state_group(bc_ID)%bc_COMM)

                    end do !itime_couple
                end do !idepend
            end do !istate


        end if



    end subroutine update_primary_bc
    !*****************************************************************************************











    !>  Update the primary field lift functions for diffusion.
    !!
    !!  This only gets computed if there are diffusive operators allocated to the 
    !!  equation set. If not, then there is no need for the lifting operators and they
    !!  are not computed.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_lift(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik) :: idomain_l, ielement_l, eqn_ID

        ! Update lifting terms for gradients if diffusive operators are present
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        if (allocated(equation_set(eqn_ID)%volume_diffusive_operator) .or. &
            allocated(equation_set(eqn_ID)%boundary_diffusive_operator)) then

            call self%update_lift_faces_internal(worker,equation_set,bc_state_group,differentiate)
            call self%update_lift_faces_external(worker,equation_set,bc_state_group,differentiate)

        end if

    end subroutine update_primary_lift
    !*****************************************************************************************




    !>  Update the adjoint field 'element' cache entries.
    !!
    !!  Adjoint fields are update only for post-processing purposes.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   8/13/2018
    !!
    !!  Added grid-node differentiation
    !!
    !!  @author Matteo Ugolotti
    !!  @date   9/13/2018
    !!
    !!  Added BC linearization
    !!
    !!  @author Matteo Ugolotti
    !!  @date   11/26/2018
    !!
    !!  Added D (distance field) linearization (not really important here)
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/10/2018
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_adjoint_element(self,worker,equation_set,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, &
                                                       iface, idiff, eqn_ID, ifunc, istep,   &
                                                       ivar
        character(:),   allocatable                 :: field
        real(rk),       allocatable                 :: ale_Dinv(:,:,:)
        real(rk),       allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        type(AD_D),     allocatable, dimension(:)   :: value_u, grad1_u, grad2_u, grad3_u, grad1_tmp, grad2_tmp, grad3_tmp

        ! For post-processing, we post process one adjoint solution per step at the time. 
        istep = 1


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        ! Element adjoint fields volume 'value' cache. Only depends on interior element
        ! NOTE: the cache handler is used only for post-processing in case of adjoint fields.
        !       Therefore, here we don't really care about the type of differentiation.
        if (differentiate == dQ_DIFF .or. &
            differentiate == dX_DIFF .or. &
            differentiate == dBC_DIFF) then
            idiff = DIAG
        else if (differentiate == NO_DIFF .or. differentiate == dD_DIFF) then
            idiff = 0
        end if


        ! Compute Value/Gradients
        idepend = 1
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff,worker%itime)
        worker%function_info%idepend = idepend
        worker%function_info%dtype   = differentiate
        do ieqn = 1,worker%prop(eqn_ID)%nadjoint_fields()
            field = worker%prop(eqn_ID)%get_adjoint_field_name(ieqn)
            ivar  = worker%prop(eqn_ID)%get_adjoint_field_index(field)
            ifunc = worker%prop(eqn_ID)%adjoint_fields(ieqn)%get_functional_ID()

            ! Interpolate modes to nodes on undeformed element
                call self%timer_interpolate%start()
            value_u = interpolate_element_autodiff(worker%mesh,worker%solverdata%adjoint%v(ifunc,istep),worker%element_info,worker%function_info,ivar,worker%itime,'value')
                call self%timer_interpolate%stop()

            ! Get ALE transformation data
            ale_g = worker%get_det_jacobian_grid_element('value')

            ! Compute transformation to deformed element
            value_u = (value_u/ale_g)

            ! Store quantities valid on the deformed element
            call worker%cache%set_data(field,'element',value_u,'value',0,worker%function_info%seed)

        end do !ieqn

    end subroutine update_adjoint_element
    !*****************************************************************************************








    !>  Update the adjoint field 'face interior' cache entries.
    !!
    !!  Adjoint fields are update only for post-processing purposes.
    !!
    !!  @author Matteo Ugolotti
    !!  @date   8/13/2018
    !!
    !!  Added grid-node differentiation
    !!
    !!  @author Matteo Ugolotti
    !!  @date   9/13/2018
    !!
    !!  Added BC linearization
    !!
    !!  @author Matteo Ugolotti
    !!  @date   11/26/2018
    !!
    !!  Added D (distance field) linearization (not really important here)
    !!
    !!  @author Matteo Ugolotti
    !!  @date   05/10/2018
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_adjoint_interior(self,worker,equation_set,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, iface, idiff, eqn_ID
        integer(ik)                                 :: ivar , ifunc, istep
        character(:),   allocatable                 :: field 
        real(rk),       allocatable                 :: ale_Dinv(:,:,:)
        real(rk),       allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        type(AD_D),     allocatable, dimension(:)   :: value_u, grad1_u, grad2_u, grad3_u, grad1_tmp, grad2_tmp, grad3_tmp

        ! No step needed in adjoint variables for io
        istep = 1

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        ! Face interior state. 'values' only depends on interior element.
        idepend = 1


        ! Set differentiation indicator
        ! NOTE: the cache handler is used only for post-processing in case of adjoint fields.
        !       Therefore, here we don't really care about the type of differentiation.
        if (differentiate == dQ_DIFF .or. &
            differentiate == dX_DIFF .or. &
            differentiate == dBC_DIFF) then
            idiff = DIAG
        else if (differentiate == NO_DIFF .or. differentiate == dD_DIFF) then
            idiff = 0
        end if


        ! Compute Values
        worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
        worker%function_info%idepend = idepend
        worker%function_info%idiff   = idiff
        worker%function_info%dtype   = differentiate
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        do ieqn = 1,worker%prop(eqn_ID)%nadjoint_fields()

            field = worker%prop(eqn_ID)%get_adjoint_field_name(ieqn)
            ivar  = worker%prop(eqn_ID)%get_adjoint_field_index(field)
            ifunc = worker%prop(eqn_ID)%adjoint_fields(ieqn)%get_functional_ID()


            ! Interpolate modes to nodes on undeformed element
            ! NOTE: we always need to compute the graduent for interior faces for boundary conditions.
                call self%timer_interpolate%start()
            value_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%adjoint%v(ifunc,istep),worker%element_info,worker%function_info,worker%iface,ieqn,worker%itime,'value',ME)
            grad1_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%adjoint%v(ifunc,istep),worker%element_info,worker%function_info,worker%iface,ieqn,worker%itime,'grad1',ME)
            grad2_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%adjoint%v(ifunc,istep),worker%element_info,worker%function_info,worker%iface,ieqn,worker%itime,'grad2',ME)
            grad3_u = interpolate_face_autodiff(worker%mesh,worker%solverdata%adjoint%v(ifunc,istep),worker%element_info,worker%function_info,worker%iface,ieqn,worker%itime,'grad3',ME)
                call self%timer_interpolate%stop()


            ! Get ALE transformation data
            ale_g       = worker%get_det_jacobian_grid_face('value','face interior')
            ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1','face interior')
            ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2','face interior')
            ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3','face interior')
            ale_Dinv    = worker%get_inv_jacobian_grid_face('face interior')


            ! Compute transformation to deformed element
            value_u   = value_u/ale_g
            grad1_tmp = grad1_u-(value_u)*ale_g_grad1
            grad2_tmp = grad2_u-(value_u)*ale_g_grad2
            grad3_tmp = grad3_u-(value_u)*ale_g_grad3

            grad1_u = (ale_Dinv(1,1,:)*grad1_tmp + ale_Dinv(2,1,:)*grad2_tmp + ale_Dinv(3,1,:)*grad3_tmp)/ale_g
            grad2_u = (ale_Dinv(1,2,:)*grad1_tmp + ale_Dinv(2,2,:)*grad2_tmp + ale_Dinv(3,2,:)*grad3_tmp)/ale_g
            grad3_u = (ale_Dinv(1,3,:)*grad1_tmp + ale_Dinv(2,3,:)*grad2_tmp + ale_Dinv(3,3,:)*grad3_tmp)/ale_g


            ! Store quantities valid on the deformed element
            call worker%cache%set_data(field,'face interior',value_u,'value',   0,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad1_u,'gradient',1,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad2_u,'gradient',2,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad3_u,'gradient',3,worker%function_info%seed,iface)

        end do !ieqn


    end subroutine update_adjoint_interior
    !*****************************************************************************************










    !>  Update the auxiliary field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_element(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, iaux, idomain_l, ielement_l, iface, &
                                                       idiff, iaux_field, ifield, eqn_ID, nfields_primary, nterms_s_primary
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        !
!        ! Element primary fields volume 'value' cache. Only depends on interior element
!        !
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if

        !
        ! Element primary fields volume 'value' cache. Only depends on interior element
        !   NB: for dQ_DIFF and dB_DIFF -> neither the interpolators nor the modal coefficients of the
        !                                  primary variables depend on the auxiliary variables.
        !       for dX_DIFF             -> The interpolators depends on the grid nodes. Differentiation 
        !                                  is needed on the interpolation side
        !       for dD_DIFF             -> The auxiliary variables needs to be differentiated wrt to themselves
        !                                  like what happend for primary variable in dQ differentiation
        !       for NO_DIFF             -> Derivatives are not needed. Neither allocation nor calculation are 
        !                                  necessary
        !
        if (differentiate == dQ_DIFF .or. &
            differentiate == dX_DIFF .or. &
            differentiate == dBC_DIFF .or. &
            differentiate == dD_DIFF) then
            idiff   = DIAG
        else if (differentiate == NO_DIFF) then
            idiff   = 0
        end if


        !idepend = 0 ! no linearization
        idepend = 1 ! no linearization
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        do iaux = 1,worker%prop(eqn_ID)%nauxiliary_fields()

            ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
            field      = worker%prop(eqn_ID)%get_auxiliary_field_name(iaux)
            iaux_field = worker%solverdata%get_auxiliary_field_index(field)

            ! Set seed
            worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff,worker%itime)
            worker%function_info%idepend = idepend
            worker%function_info%idiff   = idiff
            worker%function_info%type    = AUXILIARY 
            worker%function_info%dtype   = differentiate

            ! Interpolate modes to nodes
            ifield = 1    !implicitly assuming only 1 equation in the auxiliary field chidg_vector
                call self%timer_interpolate%start()
            value_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ifield,worker%itime,'value')
            grad1_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ifield,worker%itime,'grad1')
            grad2_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ifield,worker%itime,'grad2')
            grad3_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ifield,worker%itime,'grad3')
                call self%timer_interpolate%stop()

            ! Store gq data in cache
            call worker%cache%set_data(field,'element',value_gq,'value',   0,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad1_gq,'gradient',1,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad2_gq,'gradient',2,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad3_gq,'gradient',3,worker%function_info%seed)

        end do !iaux

    end subroutine update_auxiliary_element
    !*****************************************************************************************









    !>  Update the auxiliary field 'face interior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_interior(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ifield, idomain_l, ielement_l, iface, &
                                                       iaux_field, iaux, idiff, eqn_ID, nfields_primary, nterms_s_primary
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        ! Set differentiation indicator
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if

        !
        ! Set differentiation indicator
        !   NB: for dQ_DIFF and dB_DIFF -> neither the interpolators nor the modal coefficients of the
        !                                  primary variables depend on the auxiliary variables.
        !       for dX_DIFF             -> The interpolators depends on the grid nodes. Differentiation 
        !                                  is needed on the interpolation side
        !       for dD_DIFF             -> The auxiliary variables needs to be differentiated wrt to themselves
        !                                  like what happend for primary variable in dQ differentiation
        !       for NO_DIFF             -> Derivatives are not needed. Neither allocation nor calculation are 
        !                                  necessary
        !
        if (differentiate == dQ_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dX_DIFF .or. differentiate == dD_DIFF) then
            idiff   = DIAG
        else if (differentiate == NO_DIFF) then
            idiff   = 0
        end if

        ! Face interior state. 
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        !idepend = 0 ! no linearization
        idepend = 1 ! no linearization
        do iaux = 1,worker%prop(eqn_ID)%nauxiliary_fields()

            ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
            field      = worker%prop(eqn_ID)%get_auxiliary_field_name(iaux)
            iaux_field = worker%solverdata%get_auxiliary_field_index(field)

            ! Set seed
            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
            worker%function_info%idepend = idepend
            worker%function_info%idiff   = idiff
            worker%function_info%type    = AUXILIARY
            worker%function_info%dtype   = differentiate

            ! Interpolate modes to nodes
            ! NOTE: implicitly assuming only 1 field in the auxiliary field chidg_vector
            ifield = 1
                call self%timer_interpolate%start()
            value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'value',ME)
            grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad1',ME)
            grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad2',ME)
            grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad3',ME)
                call self%timer_interpolate%stop()

            ! Store gq data in cache
            call worker%cache%set_data(field,'face interior',value_gq,'value',   0,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

        end do !iaux

    end subroutine update_auxiliary_interior
    !*****************************************************************************************














    !>  Update the auxiliary field 'face exterior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_exterior(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, idomain_l, ielement_l, iface, &
                                                       iaux, iaux_field, ifield, idiff, eqn_ID, &
                                                       nfields_primary, nterms_s_primary, ndepend
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        ! Set differentiation indicator
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if

        !
        ! Set differentiation indicator
        !
        !   NB: for dQ_DIFF and dB_DIFF -> neither the interpolators nor the modal coefficients of the
        !                                  primary variables depend on the auxiliary variables.
        !       for dX_DIFF             -> The interpolators depends on the grid nodes. Differentiation 
        !                                  is needed on the interpolation side
        !       for dD_DIFF             -> The auxiliary variables needs to be differentiated wrt to themselves
        !                                  like what happend for primary variable in dQ differentiation
        !       for NO_DIFF             -> Derivatives are not needed. Neither allocation nor calculation are 
        !                                  necessary
        !
        if (differentiate == dQ_DIFF .or. differentiate == dBC_DIFF) then
            idiff   = DIAG
            ndepend = 1 ! no linearization
        else if (differentiate == dX_DIFF .or. differentiate == dD_DIFF) then 
            idiff   = iface
            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
        else if (differentiate == NO_DIFF) then
            idiff   = 0
            ndepend = 1 ! no linearization
        end if
        

        ! Face exterior state. 
        if ( (worker%face_type() == INTERIOR) .or. (worker%face_type() == CHIMERA) ) then

            eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
            !idepend = 0 ! no linearization
            do iaux = 1,worker%prop(eqn_ID)%nauxiliary_fields()

                ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
                field      = worker%prop(eqn_ID)%get_auxiliary_field_name(iaux)
                iaux_field = worker%solverdata%get_auxiliary_field_index(field)

                do idepend = 1,ndepend

                    ! Set seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%idiff   = idiff
                    worker%function_info%type    = AUXILIARY
                    worker%function_info%dtype   = differentiate

                    ! Interpolate modes to nodes
                    ! WARNING: implicitly assuming only 1 field in the auxiliary field chidg_vector
                    ifield = 1
                call self%timer_interpolate%start()
                    value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'value',NEIGHBOR)
                    grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad1',NEIGHBOR)
                    grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad2',NEIGHBOR)
                    grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad3',NEIGHBOR)
                call self%timer_interpolate%stop()

                    ! Store gq data in cache
                    call worker%cache%set_data(field,'face exterior',value_gq,'value',   0,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

                end do

            end do !iaux

        end if


    end subroutine update_auxiliary_exterior
    !*****************************************************************************************










    !>  Update the auxiliary field bc(face exterior) cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  NOTE: This extrapolates information from the 'face interior' and stores in in the
    !!        'face exterior' cache. These are auxiliary fields so they don't exactly have
    !!        a definition outside the domain. An extrapolation is a reasonable assumption.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!  Added grid-node differentiation
    !!  @author Matteo Ugolotti
    !!  @date   9/13/2018
    !!
    !!  Added BC linearization
    !!  @author Matteo Ugolotti
    !!  @date   11/26/2018
    !!
    !!  Added D (distance field) linearization.
    !!  @author Matteo Ugolotti
    !!  @date   05/10/2018
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_bc(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ifield, idomain_l, ielement_l, iface, &
                                                       iaux_field, iaux, idiff, eqn_ID, nfields_primary, nterms_s_primary
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


!        ! Set differentiation indicator
!        if (differentiate) then
!            idiff = DIAG
!        else
!            idiff = 0
!        end if


        !
        ! Set differentiation indicator
        !
        !   NB: for dQ_DIFF and dB_DIFF -> neither the interpolators nor the modal coefficients of the
        !                                  primary variables depend on the auxiliary variables.
        !       for dX_DIFF             -> The interpolators depends on the grid nodes. Differentiation 
        !                                  is needed on the interpolation side
        !       for dD_DIFF             -> The auxiliary variables needs to be differentiated wrt to themselves
        !                                  like what happend for primary variable in dQ differentiation
        !       for NO_DIFF             -> Derivatives are not needed. Neither allocation nor calculation are 
        !                                  necessary
        !
        ! Assuming there are no boundary couplings between boundaries of the auxiliary problem.
        if (differentiate == dQ_DIFF .or. differentiate == dBC_DIFF) then
            idiff   = DIAG
        else if (differentiate == dX_DIFF .or. differentiate == dD_DIFF) then 
            idiff   = DIAG
        else if (differentiate == NO_DIFF) then
            idiff   = 0
        end if


        ! Face interior state. 
        if ( (worker%face_type() == BOUNDARY) ) then

            eqn_ID  = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
            idepend = 0 ! no linearization
            do iaux = 1,worker%prop(eqn_ID)%nauxiliary_fields()

                ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
                field      = worker%prop(eqn_ID)%get_auxiliary_field_name(iaux)
                iaux_field = worker%solverdata%get_auxiliary_field_index(field)

                ! Set seed
                worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                worker%function_info%idepend = idepend
                worker%function_info%idiff   = idiff
                worker%function_info%type    = AUXILIARY 
                worker%function_info%dtype   = differentiate

                ! Interpolate modes to nodes
                ifield = 1    !implicitly assuming only 1 equation in the auxiliary field chidg_vector
                call self%timer_interpolate%start()
                value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'value',ME)
                grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad1',ME)
                grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad2',ME)
                grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,worker%iface,ifield,worker%itime,'grad3',ME)
                call self%timer_interpolate%stop()

                ! Store gq data in cache
                call worker%cache%set_data(field,'face exterior',value_gq,'value',   0,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

            end do !iaux

        end if


    end subroutine update_auxiliary_bc
    !*****************************************************************************************








    !>  Update the model field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_element(self,worker,equation_set,bc_state_group,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        logical                     :: diff_none, diff_interior, diff_exterior, compute_model
        integer(ik)                 :: imodel, idomain_l, ielement_l, idepend, idiff, &
                                       ipattern, ndepend, eqn_ID
        integer(ik),    allocatable :: compute_pattern(:)
        character(:),   allocatable :: dependency

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Compute element model field. Potentially differentiated wrt exterior elements.
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        worker%interpolation_source = 'element'
        do imodel = 1,equation_set(eqn_ID)%nmodels()

            ! Get model dependency
            dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()

            ! Only execute models specified in incoming model_type
            if (trim(dependency) == trim(model_type)) then

                ! Determine pattern to compute functions. Depends on if we are differentiating 
                ! or not. These will be used to set idiff, indicating the differentiation
                ! direction.
                !if (differentiate) then
                if (differentiate == dQ_DIFF .or. &
                    differentiate == dX_DIFF .or. &
                    differentiate == dBC_DIFF .or. &
                    differentiate == dD_DIFF) then
                    ! compute function, wrt (all exterior)/interior states
                    if (dependency == 'f(Q-)') then
                        compute_pattern = [DIAG]
                    else if ( (dependency == 'f(Q-,Q+)') .or. &
                              (dependency == 'f(Grad(Q))') ) then
                        compute_pattern = [1,2,3,4,5,6,DIAG]
                    else
                        call chidg_signal(FATAL,"cache_handler%update_model_element: Invalid model dependency string.")
                    end if
                else
                    ! compute function, but do not differentiate
                    compute_pattern = [0]
                end if


                ! Execute compute pattern
                do ipattern = 1,size(compute_pattern)

                    ! get differentiation indicator
                    idiff = compute_pattern(ipattern)

                    diff_none     = (idiff == 0)
                    diff_interior = (idiff == DIAG)
                    diff_exterior = ( (idiff == 1) .or. (idiff == 2) .or. &
                                      (idiff == 3) .or. (idiff == 4) .or. &
                                      (idiff == 5) .or. (idiff == 6) )



                    if (diff_interior .or. diff_none) then
                        compute_model = .true.
                    else if (diff_exterior) then
                        compute_model = ( (worker%mesh%domain(idomain_l)%faces(ielement_l,idiff)%ftype == INTERIOR) .or. &
                                          (worker%mesh%domain(idomain_l)%faces(ielement_l,idiff)%ftype == CHIMERA) )
                    end if



                    if (compute_model) then

                        if (diff_none .or. diff_interior) then
                            ndepend = 1
                        else
                            call worker%set_face(idiff)
                            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
                        end if

                        do idepend = 1,ndepend
                            worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff,worker%itime)
                            worker%function_info%idepend = idepend
                            worker%function_info%dtype   = differentiate

                            call equation_set(eqn_ID)%models(imodel)%model%compute(worker)
                        end do !idepend
                    end if !compute

                end do !ipattern

            end if ! select model type
        end do !imodel


    end subroutine update_model_element
    !*****************************************************************************************










    !>  Update the model field 'value', 'face interior' cache entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_interior(self,worker,equation_set,bc_state_group,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        logical                     :: exterior_coupling, selected_model
        integer(ik)                 :: idepend, imodel, idomain_l, ielement_l, &
                                       iface, idiff, ndepend, eqn_ID
        integer(ik),    allocatable :: compute_pattern(:)
        character(:),   allocatable :: field, model_dependency, mode
        type(AD_D),     allocatable :: value_gq(:)


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        ! Update models for 'face interior'. Differentiated wrt interior.
        idepend = 1
        eqn_ID  = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        worker%interpolation_source = 'face interior'
        do imodel = 1,equation_set(eqn_ID)%nmodels()

            ! Compute if model dependency matches specified model type in the 
            ! function interface.
            model_dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()
            selected_model = (trim(model_type) == trim(model_dependency))

            if (selected_model) then

                    !! Set differentiation indicator
                    !if (differentiate) then
                    !    idiff = DIAG
                    !else
                    !    idiff = 0 
                    !end if
                    !
                    ! Set differentiation indicator
                    !
                    if (differentiate == dQ_DIFF .or. &
                        differentiate == dX_DIFF .or. &
                        differentiate == dBC_DIFF .or. &
                        differentiate == dD_DIFF) then
                        idiff = DIAG
                    else if (differentiate == NO_DIFF) then
                        idiff = 0
                    end if


                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%idiff   = idiff
                    worker%function_info%dtype   = differentiate

                    call equation_set(eqn_ID)%models(imodel)%model%compute(worker)

            end if !select model
        end do !imodel




        ! Update models for 'face interior'. Differentiated wrt exterior.
        worker%interpolation_source = 'face interior'
        if ( (worker%face_type() == INTERIOR) .or. &
             (worker%face_type() == CHIMERA) ) then

            !if (differentiate) then
            if (differentiate == dQ_DIFF .or. &
                differentiate == dX_DIFF .or. &
                differentiate == dBC_DIFF .or. &
                differentiate == dD_DIFF) then

                do imodel = 1,equation_set(eqn_ID)%nmodels()

                    model_dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()

                    selected_model    = (trim(model_type) == trim(model_dependency))
                    exterior_coupling = (model_dependency == 'f(Q-,Q+)') .or. (model_dependency == 'f(Grad(Q))')

                    if ( selected_model .and. exterior_coupling ) then

                        ! Set differentiation indicator
                        idiff = iface

                        ! Compute the number of exterior element dependencies
                        ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)

                        ! Loop through external dependencies and compute model
                        do idepend = 1,ndepend
                            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                            worker%function_info%idepend = idepend
                            worker%function_info%idiff   = idiff
                            worker%function_info%dtype   = differentiate

                            call equation_set(eqn_ID)%models(imodel)%model%compute(worker)
                        end do !idepend

                    end if ! select model


                end do !imodel

            end if !differentiate
        end if ! INTERIOR or CHIMERA



    end subroutine update_model_interior
    !*****************************************************************************************











    !>  Update the model field 'value', 'face exterior' cache entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine update_model_exterior(self,worker,equation_set,bc_state_group,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        integer(ik)                 :: idepend, imodel, idomain_l, ielement_l, iface, &
                                       bc_ID, patch_ID, face_ID, ndepend, idiff, eqn_ID, ChiID
        character(:),   allocatable :: field, model_dependency
        logical                     :: selected_model


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface



        !
        ! Face exterior state: interior neighbors and chimera
        !
        !eqn_ID = worker%mesh%domain(idomain_l)%eqn_ID
        if (worker%face_type() == INTERIOR) then
            eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        else if (worker%face_type() == CHIMERA) then
            ChiID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ChiID
            eqn_ID = worker%mesh%domain(idomain_l)%chimera%recv(ChiID)%donor(1)%elem_info%eqn_ID
        end if




        worker%interpolation_source = 'face exterior'
        if ( (worker%face_type() == INTERIOR) .or. (worker%face_type() == CHIMERA) ) then

            !
            ! Set differentiation indicator. Differentiate 'face exterior' wrt EXTERIOR elements
            !
            !if (differentiate) then
            !    idiff = iface
            !else
            !    idiff = 0
            !end if
            if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dD_DIFF) then
                idiff = iface
            else if (differentiate == NO_DIFF) then
                idiff = 0
            end if
            

            ! 
            ! Compute the number of exterior element dependencies for face exterior state
            !
            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
            do imodel = 1,equation_set(eqn_ID)%nmodels()

                !
                ! Get model dependency 
                !
                model_dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()
                selected_model   = (trim(model_type) == trim(model_dependency))

                if (selected_model) then
                    do idepend = 1,ndepend

                        worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                        worker%function_info%idepend = idepend
                        worker%function_info%dtype   = differentiate

                        call equation_set(eqn_ID)%models(imodel)%model%compute(worker)

                    end do !idepend
                end if !select model

            end do !imodel


            !
            ! Set differentiation indicator. Differentiate 'face exterior' wrt INTERIOR element
            ! Only need to compute if differentiating
            !
            !if (differentiate) then
            if (differentiate == dQ_DIFF .or. &
                differentiate == dX_DIFF .or. &
                differentiate == dBC_DIFF .or. &
                differentiate == dD_DIFF) then

                idiff = DIAG
            
                ! Compute the number of exterior element dependencies for face exterior state
                ndepend = 1
                do imodel = 1,equation_set(eqn_ID)%nmodels()

                    ! Get model dependency 
                    model_dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()
                    selected_model   = (trim(model_type) == trim(model_dependency))

                    if (selected_model) then
                        do idepend = 1,ndepend

                            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                            worker%function_info%idepend = idepend
                            worker%function_info%dtype   = differentiate

                            call equation_set(eqn_ID)%models(imodel)%model%compute(worker)

                        end do !idepend
                    end if !select model

                end do !imodel

            end if


        end if ! worker%face_type()

    end subroutine update_model_exterior
    !*****************************************************************************************







    !>  Update the model field BOUNDARY state functions. These are placed in the 
    !!  'face exterior' cache entry.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_bc(self,worker,equation_set,bc_state_group,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        integer(ik)                 :: idepend, ieqn, idomain_l, ielement_l, iface, ndepend, &
                                       istate, bc_ID, group_ID, patch_ID, face_ID, imodel, eqn_ID, itime_start, itime_end, itime_couple
        character(:),   allocatable :: field, model_dependency
        logical                     :: selected_model


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        ! Face exterior state: boundaries
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        worker%interpolation_source = 'face exterior'
        if ( (worker%face_type() == BOUNDARY) ) then

            ! Compute the number of exterior element dependencies for face exterior state
            ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)

            bc_ID    = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%bc_ID
            group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
            patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
            face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID

            if ( worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%temporal_coupling == 'Global') then
                itime_start = 1
                itime_end   = worker%time_manager%ntime
            else
                itime_start = worker%itime
                itime_end   = worker%itime
            end if



            do imodel = 1,equation_set(eqn_ID)%nmodels()

                ! Get model dependency 
                model_dependency = equation_set(eqn_ID)%models(imodel)%model%get_dependency()
                selected_model   = (trim(model_type) == trim(model_dependency))

                if (selected_model) then
                    do idepend = 1,ndepend
                        do itime_couple = itime_start,itime_end


                            !if (differentiate) then
                            if (differentiate == dQ_DIFF .or. &
                                differentiate == dX_DIFF .or. &
                                differentiate == dBC_DIFF .or. &
                                differentiate == dD_DIFF) then

                                ! Get coupled bc element to differentiate wrt
                                worker%function_info%seed%idomain_g  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g(idepend)
                                worker%function_info%seed%idomain_l  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l(idepend)
                                worker%function_info%seed%ielement_g = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(idepend)
                                worker%function_info%seed%ielement_l = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(idepend)
                                worker%function_info%seed%iproc      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%proc(idepend)
                                worker%function_info%seed%itime      = itime_couple
                                worker%function_info%dtype           = differentiate 

                            else
                                ! Set no differentiation
                                worker%function_info%seed%idomain_g  = 0
                                worker%function_info%seed%idomain_l  = 0
                                worker%function_info%seed%ielement_g = 0
                                worker%function_info%seed%ielement_l = 0
                                worker%function_info%seed%iproc      = NO_PROC
                                worker%function_info%seed%itime      = itime_couple
                                worker%function_info%dtype           = differentiate 

                            end if


                            call equation_set(eqn_ID)%models(imodel)%model%compute(worker)

                        end do !itime_couple
                    end do !idepend
                end if !select model

            end do !imodel


        end if ! worker%face_type()



    end subroutine update_model_bc
    !*****************************************************************************************















    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine update_lift_faces_internal(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        character(:),   allocatable :: field, bc_family
        integer(ik)                 :: idomain_l, ielement_l, iface, idepend, &
                                       ndepend, BC_ID, BC_face, ifield, idiff, eqn_ID

        type(AD_D), allocatable, dimension(:), save   ::    &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z, &
            lift_gq_vol_x,  lift_gq_vol_y,  lift_gq_vol_z,  &
            lift_face_grad1, lift_face_grad2, lift_face_grad3, &
            lift_vol_grad1, lift_vol_grad2, lift_vol_grad3

        real(rk), allocatable, dimension(:,:,:) :: ale_Dinv
        real(rk), allocatable, dimension(:)   :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        ! For each face, compute the lifting operators associated with each equation for the 
        ! internal and external states and also their linearization.
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)

            associate ( weights          => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                            &
                        br2_face         => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face,                                         &
                        br2_vol          => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_vol)


            bc_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%bc_ID
            if (bc_ID /= NO_ID) then
                bc_family = bc_state_group(bc_ID)%family
            else
                bc_family = 'none'
            end if



            eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
            do ifield = 1,worker%prop(eqn_ID)%nprimary_fields()

                ! Get field
                field = worker%prop(eqn_ID)%get_primary_field_name(ifield)



                !
                ! Compute Interior lift, differentiated wrt Interior
                !

                ! Set differentiation indicator
                !if (differentiate) then
                !    idiff = DIAG
                !else
                !    idiff = 0
                !end if
                if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dD_DIFF) then
                    idiff = DIAG
                else
                    idiff  = 0
                end if


                ndepend = 1
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%dtype   = differentiate


                    ! Get interior/exterior state on deformed element
                    var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
                    var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)


                    ! Difference
                    if ( worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ftype == BOUNDARY ) then
                        var_diff = (var_p - var_m)
                    else
                        var_diff = HALF*(var_p - var_m) 
                    end if


                    ! Multiply by weights
                    var_diff_weighted = var_diff * weights


                    ! Multiply by normal. Note: normal is scaled by face jacobian.
                    var_diff_x = var_diff_weighted * worker%normal(1)
                    var_diff_y = var_diff_weighted * worker%normal(2)
                    var_diff_z = var_diff_weighted * worker%normal(3)


                    !
                    ! Standard Approach breaks the process up into several steps:
                    !   1: Project onto basis
                    !   2: Local solve for lift modes in element basis
                    !   3: Interpolate lift modes to face/volume quadrature nodes
                    !
                    ! Improved approach creates a single matrix that performs the
                    ! three steps in one MV multiply:
                    !
                    !   br2_face = [val_face][invmass][val_face_trans]
                    !   br2_vol  = [val_vol ][invmass][val_face_trans]
                    !
                    lift_gq_face_x = matmul(br2_face,var_diff_x)
                    lift_gq_face_y = matmul(br2_face,var_diff_y)
                    lift_gq_face_z = matmul(br2_face,var_diff_z)


!!!!!! TESTING
                    call self%timer_ale%start()
                    !
                    ! Get ALE transformation data
                    !
                    ale_g       = worker%get_det_jacobian_grid_face('value', 'face interior')
                    ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1', 'face interior')
                    ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2', 'face interior')
                    ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3', 'face interior')
                    ale_Dinv    = worker%get_inv_jacobian_grid_face('face interior')

                    !
                    ! Compute transformation to deformed element
                    !
                    !var_m          = var_m/ale_g ! Already transformed to physical domain when var_m was stored to cache
                    lift_gq_face_x = lift_gq_face_x-(var_m)*ale_g_grad1
                    lift_gq_face_y = lift_gq_face_y-(var_m)*ale_g_grad2
                    lift_gq_face_z = lift_gq_face_z-(var_m)*ale_g_grad3

                    lift_face_grad1 = (ale_Dinv(1,1,:)*lift_gq_face_x + ale_Dinv(2,1,:)*lift_gq_face_y + ale_Dinv(3,1,:)*lift_gq_face_z)/ale_g
                    lift_face_grad2 = (ale_Dinv(1,2,:)*lift_gq_face_x + ale_Dinv(2,2,:)*lift_gq_face_y + ale_Dinv(3,2,:)*lift_gq_face_z)/ale_g
                    lift_face_grad3 = (ale_Dinv(1,3,:)*lift_gq_face_x + ale_Dinv(2,3,:)*lift_gq_face_y + ale_Dinv(3,3,:)*lift_gq_face_z)/ale_g
                    call self%timer_ale%stop()

!!!!!! TESTING



                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_face_grad1, 'lift face', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_face_grad2, 'lift face', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_face_grad3, 'lift face', 3, worker%function_info%seed, iface)


                    ! 1: Project onto element basis
                    ! 2: Interpolate lift modes to volume quadrature nodes
                    lift_gq_vol_x = matmul(br2_vol,var_diff_x)
                    lift_gq_vol_y = matmul(br2_vol,var_diff_y)
                    lift_gq_vol_z = matmul(br2_vol,var_diff_z)

!!!!!! TESTING
                    call self%timer_ale%start()

                    !
                    ! Get ALE transformation data
                    !
                    ale_g       = worker%get_det_jacobian_grid_element('value')
                    ale_g_grad1 = worker%get_det_jacobian_grid_element('grad1')
                    ale_g_grad2 = worker%get_det_jacobian_grid_element('grad2')
                    ale_g_grad3 = worker%get_det_jacobian_grid_element('grad3')
                    ale_Dinv    = worker%get_inv_jacobian_grid_element()


                    !
                    ! Compute transformation to deformed element
                    !
                    var_m          = worker%cache%get_data(field,'element', 'value', 0, worker%function_info%seed, iface)
                    !var_m          = var_m/ale_g ! already transformed
                    lift_gq_vol_x = lift_gq_vol_x-(var_m)*ale_g_grad1
                    lift_gq_vol_y = lift_gq_vol_y-(var_m)*ale_g_grad2
                    lift_gq_vol_z = lift_gq_vol_z-(var_m)*ale_g_grad3

                    lift_vol_grad1 = (ale_Dinv(1,1,:)*lift_gq_vol_x + ale_Dinv(2,1,:)*lift_gq_vol_y + ale_Dinv(3,1,:)*lift_gq_vol_z)/ale_g
                    lift_vol_grad2 = (ale_Dinv(1,2,:)*lift_gq_vol_x + ale_Dinv(2,2,:)*lift_gq_vol_y + ale_Dinv(3,2,:)*lift_gq_vol_z)/ale_g
                    lift_vol_grad3 = (ale_Dinv(1,3,:)*lift_gq_vol_x + ale_Dinv(2,3,:)*lift_gq_vol_y + ale_Dinv(3,3,:)*lift_gq_vol_z)/ale_g

                    call self%timer_ale%stop()
!!!!!! TESTING


                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_vol_grad1, 'lift element', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_vol_grad2, 'lift element', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_vol_grad3, 'lift element', 3, worker%function_info%seed, iface)



                end do !idepend







                !
                ! Compute Interior lift, differentiated wrt Exterior
                !

                ! Set differentiation indicator
                !if (differentiate) then
                !    idiff = iface
                !else
                !    idiff = 0
                !end if
                ! Set differentiation indicator
                if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dD_DIFF) then
                    idiff = iface
                else
                    idiff  = 0
                end if




                ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%dtype   = differentiate


                    ! Get interior/exterior state
                    var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
                    var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)


                    ! Difference
                    if ( worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ftype == BOUNDARY ) then
                        var_diff = (var_p - var_m) 
                    else
                        var_diff = HALF*(var_p - var_m) 
                    end if


                    ! Multiply by weights
                    var_diff_weighted = var_diff * weights

                    ! Multiply by normal. Note: normal is scaled by face jacobian.
                    var_diff_x = var_diff_weighted * worker%normal(1)
                    var_diff_y = var_diff_weighted * worker%normal(2)
                    var_diff_z = var_diff_weighted * worker%normal(3)

                    ! Project onto element basis, evaluate at face quadrature nodes
                    lift_gq_face_x = matmul(br2_face,var_diff_x)
                    lift_gq_face_y = matmul(br2_face,var_diff_y)
                    lift_gq_face_z = matmul(br2_face,var_diff_z)

!!!!!! TESTING
                    call self%timer_ale%start()

                    !
                    ! Get ALE transformation data
                    !
                    ale_g       = worker%get_det_jacobian_grid_face('value', 'face interior')
                    ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1', 'face interior')
                    ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2', 'face interior')
                    ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3', 'face interior')
                    ale_Dinv    = worker%get_inv_jacobian_grid_face('face interior')

                    !
                    ! Compute transformation to deformed element
                    !
                    !var_m          = var_m/ale_g ! already transformed
                    lift_gq_face_x = lift_gq_face_x-(var_m)*ale_g_grad1
                    lift_gq_face_y = lift_gq_face_y-(var_m)*ale_g_grad2
                    lift_gq_face_z = lift_gq_face_z-(var_m)*ale_g_grad3


                    lift_face_grad1 = (ale_Dinv(1,1,:)*lift_gq_face_x + ale_Dinv(2,1,:)*lift_gq_face_y + ale_Dinv(3,1,:)*lift_gq_face_z)/ale_g
                    lift_face_grad2 = (ale_Dinv(1,2,:)*lift_gq_face_x + ale_Dinv(2,2,:)*lift_gq_face_y + ale_Dinv(3,2,:)*lift_gq_face_z)/ale_g
                    lift_face_grad3 = (ale_Dinv(1,3,:)*lift_gq_face_x + ale_Dinv(2,3,:)*lift_gq_face_y + ale_Dinv(3,3,:)*lift_gq_face_z)/ale_g

                    call self%timer_ale%stop()

!!!!!! TESTING

                    
                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_face_grad1, 'lift face', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_face_grad2, 'lift face', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_face_grad3, 'lift face', 3, worker%function_info%seed, iface)


                    ! Project onto element basis, evaluate at element quadrature nodes
                    lift_gq_vol_x = matmul(br2_vol,var_diff_x)
                    lift_gq_vol_y = matmul(br2_vol,var_diff_y)
                    lift_gq_vol_z = matmul(br2_vol,var_diff_z)

!!!!!! TESTING
                    call self%timer_ale%start()

                    !
                    ! Get ALE transformation data
                    !
                    ale_g       = worker%get_det_jacobian_grid_element('value')
                    ale_g_grad1 = worker%get_det_jacobian_grid_element('grad1')
                    ale_g_grad2 = worker%get_det_jacobian_grid_element('grad2')
                    ale_g_grad3 = worker%get_det_jacobian_grid_element('grad3')
                    ale_Dinv    = worker%get_inv_jacobian_grid_element()


                    !
                    ! Compute transformation to deformed element
                    !
                    var_m         = worker%cache%get_data(field,'element', 'value', 0, worker%function_info%seed, iface)
                    !var_m         = var_m/ale_g ! already transformed
                    lift_gq_vol_x = lift_gq_vol_x-(var_m)*ale_g_grad1
                    lift_gq_vol_y = lift_gq_vol_y-(var_m)*ale_g_grad2
                    lift_gq_vol_z = lift_gq_vol_z-(var_m)*ale_g_grad3

                    lift_vol_grad1 = (ale_Dinv(1,1,:)*lift_gq_vol_x + ale_Dinv(2,1,:)*lift_gq_vol_y + ale_Dinv(3,1,:)*lift_gq_vol_z)/ale_g
                    lift_vol_grad2 = (ale_Dinv(1,2,:)*lift_gq_vol_x + ale_Dinv(2,2,:)*lift_gq_vol_y + ale_Dinv(3,2,:)*lift_gq_vol_z)/ale_g
                    lift_vol_grad3 = (ale_Dinv(1,3,:)*lift_gq_vol_x + ale_Dinv(2,3,:)*lift_gq_vol_y + ale_Dinv(3,3,:)*lift_gq_vol_z)/ale_g

                    call self%timer_ale%stop()

!!!!!! TESTING

                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_vol_grad1, 'lift element', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_vol_grad2, 'lift element', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_vol_grad3, 'lift element', 3, worker%function_info%seed, iface)



                end do !idepend

            end do !ifield


            end associate

        end do !iface


    end subroutine update_lift_faces_internal
    !*****************************************************************************************










    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_lift_faces_external(self,worker,equation_set,bc_state_group,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik) :: idomain_l, ielement_l, iface, idepend, ieqn, &
                       ndepend, BC_ID, BC_face, idiff
        logical     :: boundary_face, interior_face, chimera_face


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        ! For each face, compute the lifting operators associated with each equation for the 
        ! internal and external states and also their linearization.
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)

            ! Check if boundary or interior
            boundary_face = (worker%face_type() == BOUNDARY)
            interior_face = (worker%face_type() == INTERIOR)
            chimera_face  = (worker%face_type() == CHIMERA )

            ! Compute lift for each equation
            do ieqn = 1,worker%mesh%domain(idomain_l)%nfields


                !
                ! Compute External lift, differentiated wrt Interior
                !

                ! Set differentiation indicator
                !if (differentiate) then
                !    idiff = DIAG
                !else
                !    idiff = 0
                !end if
                if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dD_DIFF) then
                    idiff = DIAG
                else
                    idiff = 0
                end if


                ndepend = 1
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%dtype   = differentiate


                    if (interior_face) then
                        call handle_external_lift__interior_face(worker,equation_set,bc_state_group,ieqn)
                    else if (boundary_face) then
                        call handle_external_lift__boundary_face(worker,equation_set,bc_state_group,ieqn)
                    else if (chimera_face) then
                        call handle_external_lift__chimera_face( worker,equation_set,bc_state_group,ieqn)
                    else
                        call chidg_signal(FATAL,"update_lift_faces_external: unsupported face type")
                    end if


                end do !idepend




                !
                ! Compute External lift, differentiated wrt Exterior
                !

                !! Set differentiation indicator
                !if (differentiate) then
                !    idiff = iface
                !else
                !    idiff = 0
                !end if
                ! Set differentiation indicator
                if (differentiate == dQ_DIFF .or. differentiate == dX_DIFF .or. differentiate == dBC_DIFF .or. differentiate == dD_DIFF) then
                    idiff = iface
                else
                    idiff = 0
                end if



                ndepend = get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate)
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff,worker%itime)
                    worker%function_info%idepend = idepend
                    worker%function_info%dtype   = differentiate

                    if (interior_face) then
                        call handle_external_lift__interior_face(worker,equation_set,bc_state_group,ieqn)
                    else if (boundary_face) then
                        call handle_external_lift__boundary_face(worker,equation_set,bc_state_group,ieqn)
                    else if (chimera_face) then
                        call handle_external_lift__chimera_face( worker,equation_set,bc_state_group,ieqn)
                    else
                        call chidg_signal(FATAL,"update_lift_faces_external: unsupported face type")
                    end if


                end do !idepend

            end do !ieqn



        end do !iface


    end subroutine update_lift_faces_external
    !*****************************************************************************************
















    !>  Handle computing lift for an external element, when the face is an interior face.
    !!
    !!  In this case, the external element exists and we can just use its data. This is 
    !!  not the case for a boundary condition face, and it is complicated further by a 
    !!  Chimera boundary face.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__interior_face(worker,equation_set,bc_state_group,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface, idomain_l_n, ielement_l_n, iface_n, iproc_n, eqn_ID
        logical     :: boundary_face, interior_face, local_neighbor, remote_neighbor

        type(AD_D), allocatable, dimension(:)   ::              &
            var_m, var_p, var_diff, var_diff_weighted,          &
            var_diff_x,     var_diff_y,     var_diff_z,         &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z,     &
            lift_face_grad1, lift_face_grad2, lift_face_grad3,  &
            normx, normy, normz

        character(:),   allocatable                     :: field
        real(rk),       allocatable, dimension(:)       :: weights, ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        real(rk),       allocatable, dimension(:,:)     :: br2_face
        real(rk),       allocatable, dimension(:,:,:)   :: ale_Dinv


        !
        ! Interior element
        ! 
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Neighbor element
        !
        idomain_l_n  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ineighbor_domain_l
        ielement_l_n = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ineighbor_element_l
        iface_n      = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ineighbor_face
        iproc_n      = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ineighbor_proc

        local_neighbor  = (iproc_n == IRANK)
        remote_neighbor = (iproc_n /= IRANK)


        !
        ! Get field
        !
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        field = worker%prop(eqn_ID)%get_primary_field_name(ieqn)


        if ( local_neighbor ) then
            weights          = worker%mesh%domain(idomain_l_n)%elems(ielement_l_n)%basis_s%weights_face(iface_n)
            br2_face         = worker%mesh%domain(idomain_l_n)%faces(ielement_l_n,iface_n)%br2_face


        else if ( remote_neighbor ) then
            ! User local element gq instance. Assumes same order of accuracy.
            weights          = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface_n)
            br2_face         = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%neighbor_br2_face


        end if



            ! Use reverse of interior element's normal vector
            !normx = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            !normy = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            !normz = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,3)
            normx = -worker%normal(1)
            normy = -worker%normal(2)
            normz = -worker%normal(3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)


            ! Difference. Relative to exterior element, so reversed
            ! Relative to the exterior element, var_m is the exterior state
            ! and var_p is the interior state.
            var_diff = HALF*(var_m - var_p) 

            ! Multiply by weights
            var_diff_weighted = var_diff * weights

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz

            ! 1: Lift boundary difference. Project into element basis.
            ! 2: Evaluate lift modes at face quadrature nodes
            lift_gq_face_x = matmul(br2_face,var_diff_x)
            lift_gq_face_y = matmul(br2_face,var_diff_y)
            lift_gq_face_z = matmul(br2_face,var_diff_z)


!!!!!! TESTING

            !
            ! Get ALE transformation data
            !
            ale_g       = worker%get_det_jacobian_grid_face('value', 'face exterior')
            ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1', 'face exterior')
            ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2', 'face exterior')
            ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3', 'face exterior')
            ale_Dinv    = worker%get_inv_jacobian_grid_face('face exterior')

            !
            ! Compute transformation to deformed element
            !
            !var_p          = var_p/ale_g ! already transformed
            lift_gq_face_x = lift_gq_face_x-(var_p)*ale_g_grad1
            lift_gq_face_y = lift_gq_face_y-(var_p)*ale_g_grad2
            lift_gq_face_z = lift_gq_face_z-(var_p)*ale_g_grad3

            lift_face_grad1 = (ale_Dinv(1,1,:)*lift_gq_face_x + ale_Dinv(2,1,:)*lift_gq_face_y + ale_Dinv(3,1,:)*lift_gq_face_z)/ale_g
            lift_face_grad2 = (ale_Dinv(1,2,:)*lift_gq_face_x + ale_Dinv(2,2,:)*lift_gq_face_y + ale_Dinv(3,2,:)*lift_gq_face_z)/ale_g
            lift_face_grad3 = (ale_Dinv(1,3,:)*lift_gq_face_x + ale_Dinv(2,3,:)*lift_gq_face_y + ale_Dinv(3,3,:)*lift_gq_face_z)/ale_g


!!!!!! TESTING

            
            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_face_grad1, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_face_grad2, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_face_grad3, 'lift face', 3, worker%function_info%seed, iface)


    end subroutine handle_external_lift__interior_face
    !*****************************************************************************************














    !>  Handle computing lift for an external element, when the face is a boundary face.
    !!
    !!  In this case, the external element does NOT exist, so we use the interior element. 
    !!  !This is kind of like assuming that a boundary element exists of equal size to 
    !!  !the interior element.
    !!
    !!  Actually, on the boundary, we basically just need the interior lift because we aren't
    !!  computing an average flux. Rather we are just computing a boundary flux, so here we
    !!  essentially compute the interior lift and use it for the boundary.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__boundary_face(worker,equation_set,bc_state_group,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface, iface_n, eqn_ID, bc_ID
        logical     :: boundary_face, interior_face

        type(AD_D), allocatable, dimension(:)   ::          &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            lift_gq_x,      lift_gq_y,      lift_gq_z,      &
            lift_grad1,     lift_grad2,     lift_grad3,     &
            normx,          normy,          normz

        character(:),   allocatable                     :: field, bc_family
        real(rk),       allocatable, dimension(:)       :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        real(rk),       allocatable, dimension(:,:,:)   :: ale_Dinv


        !
        ! Interior element
        ! 
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Get field
        !
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        field = worker%prop(eqn_ID)%get_primary_field_name(ieqn)


        bc_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%bc_ID
        if (bc_ID /= NO_ID) then
            bc_family = bc_state_group(bc_ID)%family
        else
            bc_family = 'none'
        end if

        ! NEW
        associate ( weights          => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),  &
                    br2_face         => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face)

            ! Get normal vector. Use reverse of the normal vector from the interior element since no exterior element exists.
            !normx = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            !normy = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            !normz = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,3)
            normx = worker%normal(1)
            normy = worker%normal(2)
            normz = worker%normal(3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

            ! Difference. Relative to exterior element, so reversed
            var_diff = (var_p - var_m) 

            ! Multiply by weights
            var_diff_weighted = var_diff * weights

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz

            ! 1: Lift boundary difference. Project into element basis.
            ! 2: Evaluate lift modes at face quadrature nodes
            lift_gq_x = matmul(br2_face,var_diff_x)
            lift_gq_y = matmul(br2_face,var_diff_y)
            lift_gq_z = matmul(br2_face,var_diff_z)

!!!!!! TESTING

            ! Get ALE transformation data
            ale_g       = worker%get_det_jacobian_grid_face('value', 'face exterior')
            ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1', 'face exterior')
            ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2', 'face exterior')
            ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3', 'face exterior')
            ale_Dinv    = worker%get_inv_jacobian_grid_face('face exterior')

            ! Compute transformation to deformed element
            !var_p     = var_p/ale_g ! already transformed
            lift_gq_x = lift_gq_x-(var_p)*ale_g_grad1
            lift_gq_y = lift_gq_y-(var_p)*ale_g_grad2
            lift_gq_z = lift_gq_z-(var_p)*ale_g_grad3

            lift_grad1 = (ale_Dinv(1,1,:)*lift_gq_x + ale_Dinv(2,1,:)*lift_gq_y + ale_Dinv(3,1,:)*lift_gq_z)/ale_g
            lift_grad2 = (ale_Dinv(1,2,:)*lift_gq_x + ale_Dinv(2,2,:)*lift_gq_y + ale_Dinv(3,2,:)*lift_gq_z)/ale_g
            lift_grad3 = (ale_Dinv(1,3,:)*lift_gq_x + ale_Dinv(2,3,:)*lift_gq_y + ale_Dinv(3,3,:)*lift_gq_z)/ale_g

!!!!!! TESTING
            

            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_grad1, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_grad2, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_grad3, 'lift face', 3, worker%function_info%seed, iface)


        end associate




    end subroutine handle_external_lift__boundary_face
    !*****************************************************************************************












    !>  Handle computing lift for an external element, when the face is a Chimera face.
    !!
    !!  In this case, potentially multiple external elements exist, so we don't have just
    !!  a single exterior mass matrix.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__chimera_face(worker,equation_set,bc_state_group,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface, idomain_l_n, ielement_l_n, iface_n, eqn_ID
        logical     :: boundary_face, interior_face

        type(AD_D), allocatable, dimension(:)   ::          &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z, &
            lift_grad1, lift_grad2, lift_grad3,             &
            normx, normy, normz

        character(:),   allocatable                     :: field
        real(rk),       allocatable, dimension(:)       :: ale_g, ale_g_grad1, ale_g_grad2, ale_g_grad3
        real(rk),       allocatable, dimension(:,:,:)   :: ale_Dinv


        ! Interior element
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        ! Get field
        eqn_ID = worker%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        field = worker%prop(eqn_ID)%get_primary_field_name(ieqn)

        ! Use components from receiver element since no single element exists to act 
        ! as the exterior element. This implicitly treats the diffusion terms as if 
        ! there were a reflected element like the receiver element that was acting as 
        ! the donor.
        associate ( weights        => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                            &
                    br2_face       => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face )


            ! Use reversed normal vectors of receiver element
            !normx = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            !normy = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            !normz = -worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%norm(:,3)
            normx = -worker%normal(1)
            normy = -worker%normal(2)
            normz = -worker%normal(3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

            ! Difference. Relative to exterior element, so reversed
            var_diff = HALF*(var_m - var_p) 

            ! Multiply by weights
            var_diff_weighted = var_diff * weights

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz

            ! 1: Lift boundary difference. Project into element basis.
            ! 2: Evaluate lift modes at face quadrature nodes
            lift_gq_face_x = matmul(br2_face,var_diff_x)
            lift_gq_face_y = matmul(br2_face,var_diff_y)
            lift_gq_face_z = matmul(br2_face,var_diff_z)


!!!!!! TESTING


            !
            ! Get ALE transformation data
            !
            ale_g       = worker%get_det_jacobian_grid_face('value', 'face exterior')
            ale_g_grad1 = worker%get_det_jacobian_grid_face('grad1', 'face exterior')
            ale_g_grad2 = worker%get_det_jacobian_grid_face('grad2', 'face exterior')
            ale_g_grad3 = worker%get_det_jacobian_grid_face('grad3', 'face exterior')
            ale_Dinv    = worker%get_inv_jacobian_grid_face('face exterior')

            !
            ! Compute transformation to deformed element
            !
            !var_p          = var_p/ale_g ! already transformed
            lift_gq_face_x = lift_gq_face_x-(var_p)*ale_g_grad1
            lift_gq_face_y = lift_gq_face_y-(var_p)*ale_g_grad2
            lift_gq_face_z = lift_gq_face_z-(var_p)*ale_g_grad3

            lift_grad1 = (ale_Dinv(1,1,:)*lift_gq_face_x + ale_Dinv(2,1,:)*lift_gq_face_y + ale_Dinv(3,1,:)*lift_gq_face_z)/ale_g
            lift_grad2 = (ale_Dinv(1,2,:)*lift_gq_face_x + ale_Dinv(2,2,:)*lift_gq_face_y + ale_Dinv(3,2,:)*lift_gq_face_z)/ale_g
            lift_grad3 = (ale_Dinv(1,3,:)*lift_gq_face_x + ale_Dinv(2,3,:)*lift_gq_face_y + ale_Dinv(3,3,:)*lift_gq_face_z)/ale_g

!!!!!! TESTING



            
            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_grad1, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_grad2, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_grad3, 'lift face', 3, worker%function_info%seed, iface)

        end associate


    end subroutine handle_external_lift__chimera_face
    !*****************************************************************************************







    !>  For a given state of the chidg_worker(idomain,ielement,iface), return the number
    !!  of exterior dependent elements.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !----------------------------------------------------------------------------------------
    function get_ndepend_exterior(worker,equation_set,bc_state_group,differentiate) result(ndepend)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_state_group_t),     intent(inout)   :: bc_state_group(:)
        integer(ik),                intent(in)      :: differentiate

        integer(ik) :: ndepend, idomain_l, ielement_l, iface, &
                       ChiID, group_ID, patch_ID, face_ID

        if (differentiate == NO_DIFF) then

            ndepend = 1

        else

            idomain_l  = worker%element_info%idomain_l 
            ielement_l = worker%element_info%ielement_l 
            iface      = worker%iface

            ! Compute the number of exterior element dependencies for face exterior state
            if ( worker%face_type() == INTERIOR ) then
                ndepend = 1
                
            else if ( worker%face_type() == CHIMERA ) then
                ChiID   = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%ChiID
                ndepend = worker%mesh%domain(idomain_l)%chimera%recv(ChiID)%ndonors()

            else if ( worker%face_type() == BOUNDARY ) then
                group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
                patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
                face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID
                ndepend  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%ncoupled_elements(face_ID)

            end if

        end if

    end function get_ndepend_exterior
    !****************************************************************************************





















end module type_cache_handler
