!-------------------------------------------------------------------------------------
!!
!!                                  A ChiDG Worker
!!
!!  Purpose:
!!  ----------------------------------------
!!  The chidg_worker_t handles the following activities that might occur within
!!  an operator_t:
!!      - interpolate to quadrature nodes. Element and face sets.
!!      - integrate. Volume and Boundaries
!!      - return geometric information such as normals, and coordinates.
!!
!!  The worker knows what element/face is currently being worked on. So, it can then
!!  access that element/face for getting data, performing the correct interpolation,
!!  performing the correct integral. This way, the operator_t flux routines don't
!!  have to worry about where they are getting data from. 
!!
!!  The operator_t's are just concerned with getting information from the worker 
!!  about the element/face, computing a function value, passing that information
!!  back to the worker to be integrated and stored.
!!
!!
!!
!!  @author Nathan A. Wukie
!!  @date   8/22/2016
!!
!!
!-------------------------------------------------------------------------------------
module type_chidg_worker
#include <messenger.h>
    use mod_kinds,              only: ik, rk
    use mod_io,                 only: face_lift_stab, elem_lift_stab
    use mod_constants,          only: NFACES, ME, NEIGHBOR, BC, ZERO, CHIMERA,  &
                                      ONE, THIRD, TWO, NOT_A_FACE, BOUNDARY,    &
                                      CARTESIAN, CYLINDRICAL, INTERIOR, HALF,   &
                                      FOUR, NO_ID

    use mod_inv,                only: inv
    use mod_interpolate,        only: interpolate_element_autodiff, interpolate_general_autodiff
    use mod_polynomial,         only: polynomial_val
    use mod_integrate,          only: integrate_boundary_scalar_flux, &
                                      integrate_volume_vector_flux,   &
                                      integrate_volume_scalar_source, &
                                      store_volume_integrals

    use type_point,             only: point_t
    use type_mesh,              only: mesh_t
    use type_solverdata,        only: solverdata_t
    use type_time_manager,      only: time_manager_t
    use type_element_info,      only: element_info_t
    use type_face_info,         only: face_info_t
    use type_function_info,     only: function_info_t
    use type_chidg_cache,       only: chidg_cache_t
    use type_properties,        only: properties_t
    use DNAD_D
    implicit none





    !>  The ChiDG worker implementation.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !------------------------------------------------------------------------------
    type, public :: chidg_worker_t
    
        type(mesh_t),           pointer :: mesh
        type(solverdata_t),     pointer :: solverdata
        type(chidg_cache_t),    pointer :: cache
        type(time_manager_t),   pointer :: time_manager
        !type(properties_t),     pointer :: prop(:)
        type(properties_t), allocatable :: prop(:)


        type(element_info_t)        :: element_info
        type(function_info_t)       :: function_info
        integer(ik)                 :: iface
        integer(ik)                 :: itime        ! Time index
        real(rk)                    :: t            ! Physical time
    
        character(:),   allocatable :: interpolation_source
        logical                     :: contains_lift

    contains 
    
        ! Worker state
        procedure   :: init
        procedure   :: set_element          ! Set element_info type
        procedure   :: set_function_info    ! Set function_info type
        procedure   :: set_face             ! Set iface index
        procedure   :: face_info            ! Return a face_info type

        ! Worker get/set data
        procedure   :: interpolate_field
        procedure   :: interpolate_field_general
        procedure   :: get_field
        procedure   :: check_field_exists
        procedure   :: store_bc_state
        procedure   :: store_model_field

        procedure   :: get_octree_rbf_indices
        procedure   :: get_ndepend_simple


        ! BEGIN DEPRECATED
        procedure, private   :: get_primary_field_general
        procedure, private   :: get_primary_field_face
        procedure, private   :: get_primary_field_element
        procedure, private   :: get_model_field_general
        procedure, private   :: get_model_field_face
        procedure, private   :: get_model_field_element
        procedure            :: get_auxiliary_field_general
        procedure            :: get_auxiliary_field_face
        procedure            :: get_auxiliary_field_element
        ! ALE
        procedure, private   :: get_primary_field_value_ale_element
        procedure, private   :: get_primary_field_grad_ale_element
        procedure, private   :: get_primary_field_value_ale_face
        procedure, private   :: get_primary_field_grad_ale_face
        procedure, private   :: get_primary_field_value_ale_general
        procedure, private   :: get_primary_field_grad_ale_general
        ! END DEPRECATED

        ! Element/Face data access procedures
        procedure   :: normal
        procedure   :: unit_normal
        procedure   :: unit_normal_ale

        procedure   :: coords
        procedure   :: x
        procedure   :: y
        procedure   :: z
        procedure   :: coordinate
        procedure   :: coordinate_arbitrary

        procedure   :: element_size
        procedure   :: solution_order
        procedure   :: quadrature_weights
        procedure   :: inverse_jacobian
        procedure   :: face_area
        procedure   :: volume
        procedure   :: centroid
        procedure   :: coordinate_system
        procedure   :: face_type
        procedure   :: time
        procedure   :: nnodes1d
        procedure   :: h_smooth

        procedure   :: get_area_ratio
        procedure   :: get_grid_velocity_element
        procedure   :: get_grid_velocity_face
        procedure   :: get_inv_jacobian_grid_element
        procedure   :: get_inv_jacobian_grid_face
        procedure   :: get_det_jacobian_grid_element
        procedure   :: get_det_jacobian_grid_face

        ! Shock sensor procedures
        procedure   :: get_pressure_jump_indicator
        procedure   :: get_pressure_jump_shock_sensor

        ! Integration procedures
        procedure   :: integrate_boundary_average
        procedure   :: integrate_boundary_upwind
        procedure   :: integrate_boundary_condition

        procedure   :: integrate_volume_flux
        procedure   :: integrate_volume_source
        procedure   :: accumulate_residual

        ! Projection
        procedure   :: project_from_nodes

        ! Worker auxiliary flux processing procedures. Used internally
        procedure, private:: post_process_volume_advective_flux_ale
        procedure, private:: post_process_boundary_advective_flux_ale
        procedure, private:: post_process_volume_diffusive_flux_ale
        procedure, private:: post_process_boundary_diffusive_flux_ale

        final       :: destructor
    
    end type chidg_worker_t
    !*********************************************************************************






contains



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !---------------------------------------------------------------------------------
    subroutine init(self,mesh,prop,solverdata,time_manager,cache)
        class(chidg_worker_t),  intent(inout)       :: self
        type(mesh_t),           intent(in), target  :: mesh
        type(properties_t),     intent(in), target  :: prop(:)
        type(solverdata_t),     intent(in), target  :: solverdata
        type(time_manager_t),   intent(in), target  :: time_manager
        type(chidg_cache_t),    intent(in), target  :: cache

        character(:),   allocatable :: temp_name

        self%mesh       => mesh
        ! having issue with using a pointer here for prop. Theory is that the compiler
        ! creates a temporary array of prop(:) from eqnset(:)%prop when it is passing it in. 
        ! Then after this routine exists, that array ceases to exist and so
        ! points to nothing. For now we will just assign, but probably want this
        ! linked back up in the future.
        self%prop       =  prop
        !self%prop       => prop
        self%solverdata => solverdata
        self%time_manager => time_manager
        self%cache      => cache

    end subroutine init
    !**********************************************************************************






    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !----------------------------------------------------------------------------------
    subroutine set_element(self,elem_info)
        class(chidg_worker_t),  intent(inout)   :: self
        type(element_info_t),   intent(in)      :: elem_info

        self%element_info = elem_info

    end subroutine set_element
    !**********************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !---------------------------------------------------------------------------------
    subroutine set_function_info(self,fcn_info)
        class(chidg_worker_t),  intent(inout)   :: self
        type(function_info_t),  intent(in)      :: fcn_info

        self%function_info = fcn_info

    end subroutine set_function_info
    !**********************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !--------------------------------------------------------------------------------------
    subroutine set_face(self,iface)
        class(chidg_worker_t),  intent(inout)   :: self
        integer(ik),            intent(in)      :: iface

        self%iface = iface

    end subroutine set_face
    !***************************************************************************************








    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    function face_info(self) result(face_info_)
        class(chidg_worker_t),  intent(in)  :: self
        
        type(face_info_t)   :: face_info_

        face_info_%idomain_g  = self%element_info%idomain_g
        face_info_%idomain_l  = self%element_info%idomain_l
        face_info_%ielement_g = self%element_info%ielement_g
        face_info_%ielement_l = self%element_info%ielement_l
        face_info_%iface      = self%iface

    end function face_info
    !***************************************************************************************











    !>  Return a primary field evaluated at a quadrature node set. The source here
    !!  is determined by chidg_worker.
    !!
    !!  This routine is specifically for model_t's, because we want them to be evaluated
    !!  on face and element sets the same way. So in a model implementation, we just
    !!  want the model to get some quadrature node set to operate on. The chidg_worker
    !!  handles what node set is currently being returned.
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !--------------------------------------------------------------------------------------
    function get_primary_field_general(self,field,interp_type) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type

        type(AD_D), allocatable :: var_gq(:)


        if (self%interpolation_source == 'element') then
            var_gq = self%get_primary_field_element(field,interp_type) 
        else if (self%interpolation_source == 'face interior') then
            var_gq = self%get_primary_field_face(field,interp_type,'face interior')
        else if (self%interpolation_source == 'face exterior') then
            var_gq = self%get_primary_field_face(field,interp_type,'face exterior')
        else if (self%interpolation_source == 'boundary') then
            var_gq = self%get_primary_field_face(field,interp_type,'boundary')
        end if

    end function get_primary_field_general
    !**************************************************************************************








    !>  Return an auxiliary field evaluated at a quadrature node set. The source here
    !!  is determined by chidg_worker.
    !!
    !!  This routine is specifically for model_t's, because we want them to be evaluated
    !!  on face and element sets the same way. So in a model implementation, we just
    !!  want the model to get some quadrature node set to operate on. The chidg_worker
    !!  handles what node set is currently being returned.
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !--------------------------------------------------------------------------------------
    function get_auxiliary_field_general(self,field,interp_type) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type

        !type(AD_D), allocatable :: var_gq(:)
        real(rk), allocatable :: var_gq(:)


        if (self%interpolation_source == 'element') then
            var_gq = self%get_auxiliary_field_element(field,interp_type) 
        else if (self%interpolation_source == 'face interior') then
            var_gq = self%get_auxiliary_field_face(field,interp_type,'face interior')
        else if (self%interpolation_source == 'face exterior') then
            var_gq = self%get_auxiliary_field_face(field,interp_type,'face exterior')
        else if (self%interpolation_source == 'boundary') then
            var_gq = self%get_auxiliary_field_face(field,interp_type,'boundary')
        end if

    end function get_auxiliary_field_general
    !**************************************************************************************















    !>  Return a primary field interpolated to a face quadrature node set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !--------------------------------------------------------------------------------------
    function get_primary_field_face(self,field,interp_type,interp_source) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable, dimension(:)   :: var_gq
        character(:),   allocatable                 :: cache_component, cache_type, user_msg
        type(face_info_t)                           :: face_info
        integer(ik)                                 :: idirection, igq



        !
        ! Set cache_component
        !
        if (interp_source == 'face interior') then
            cache_component = 'face interior'
        else if (interp_source == 'face exterior' .or. &
                 interp_source == 'boundary') then
            cache_component = 'face exterior'
        else
            user_msg = "chidg_worker%get_primary_field_face: Invalid value for interpolation source. &
                        Try 'face interior', 'face exterior', or 'boundary'"
            call chidg_signal_two(FATAL,user_msg,trim(field),trim(interp_source))
        end if


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (interp_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (interp_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (interp_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3


        else if ( (interp_type == 'grad1 + lift') .or. &
                  (interp_type == 'grad1+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 1
        else if ( (interp_type == 'grad2 + lift') .or. &
                  (interp_type == 'grad2+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 2
        else if ( (interp_type == 'grad3 + lift') .or. &
                  (interp_type == 'grad3+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 3
        else
            user_msg = "chidg_worker%get_primary_field_face: Invalid interpolation &
                        type. 'value', 'grad1', 'grad2', 'grad3', 'grad1+lift', 'grad2+lift', 'grad3+lift'"
            call chidg_signal(FATAL,user_msg)
        end if



        !
        ! Retrieve data from cache
        !
        if (cache_type == 'value') then
            var_gq = self%cache%get_data(field,cache_component,'value',idirection,self%function_info%seed,self%iface)

        else if (cache_type == 'gradient') then
            var_gq = self%cache%get_data(field,cache_component,'gradient',idirection,self%function_info%seed,self%iface)

        else if (cache_type == 'gradient + lift') then
            var_gq = self%cache%get_data(field,cache_component,'gradient',idirection,self%function_info%seed,self%iface)

            ! Modify derivative by face lift stabilized by a factor of NFACES
            if (self%contains_lift) then
                var_gq = var_gq + real(NFACES,rk)*self%cache%get_data(field,cache_component,'lift face',idirection,self%function_info%seed,self%iface)
            end if

        end if


    end function get_primary_field_face
    !***************************************************************************************










    !>  Return a primary field interpolated to an element quadrature node set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    function get_primary_field_element(self,field,interp_type,Pmin,Pmax) result(var_gq)
        class(chidg_worker_t),  intent(in)              :: self
        character(*),           intent(in)              :: field
        character(*),           intent(in)              :: interp_type
        integer(ik),            intent(in), optional    :: Pmin
        integer(ik),            intent(in), optional    :: Pmax

        type(AD_D),     allocatable, dimension(:) :: var_gq, tmp_gq

        type(face_info_t)               :: face_info
        character(:),   allocatable     :: cache_component, cache_type, user_msg
        integer(ik)                     :: idirection, igq, iface, ifield, idomain_l, ielement_l, eqn_ID


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (interp_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (interp_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (interp_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3


        else if ( (interp_type == 'grad1 + lift') .or. &
                  (interp_type == 'grad1+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 1
        else if ( (interp_type == 'grad2 + lift') .or. &
                  (interp_type == 'grad2+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 2
        else if ( (interp_type == 'grad3 + lift') .or. &
                  (interp_type == 'grad3+lift'  ) ) then
            cache_type = 'gradient + lift'
            idirection = 3
        else
            user_msg = "chidg_worker%get_primary_field_element: Invalid interpolation &
                        type. 'value', 'grad1', 'grad2', 'grad3', 'grad1+lift', 'grad2+lift', 'grad3+lift'"
            call chidg_signal(FATAL,user_msg)
        end if




        !
        ! If we are requesting an interpolation from a subset of the modal expansion, 
        ! then perform a new interpolation rather than using the cache.
        !
        if (present(Pmin) .or. present(Pmax)) then

            if (cache_type == 'value') then
                idomain_l = self%element_info%idomain_l
                ielement_l = self%element_info%ielement_l
                eqn_ID    = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
                ifield    = self%prop(eqn_ID)%get_primary_field_index(field)

                var_gq = interpolate_element_autodiff(self%mesh, self%solverdata%q, self%element_info, self%function_info, ifield, self%itime, interp_type, mode_min=Pmin, mode_max=Pmax)

            else if ( (cache_type == 'gradient') .or. &
                      (cache_type == 'gradient + lift') ) then
                user_msg = "chidg_worker%get_primary_field_element: On partial field interpolations, &
                            only the 'value' of the field can be interpolated. 'gradient' is not yet implemented."
                call chidg_signal(FATAL,user_msg)
            end if

    

        else


            !
            ! Retrieve data from cache
            !
            if ( cache_type == 'value') then
                var_gq = self%cache%get_data(field,'element','value',idirection,self%function_info%seed)

            else if (cache_type == 'gradient') then
                var_gq = self%cache%get_data(field,'element','gradient',idirection,self%function_info%seed)

            else if (cache_type == 'gradient + lift') then
                var_gq = self%cache%get_data(field,'element','gradient',idirection,self%function_info%seed)

                ! Add lift contributions from each face
                if (self%contains_lift) then
                    do iface = 1,NFACES
                        tmp_gq = self%cache%get_data(field,'face interior', 'lift element', idirection, self%function_info%seed,iface)
                        var_gq = var_gq + tmp_gq
                    end do
                end if

            end if


        end if


    end function get_primary_field_element
    !***************************************************************************************




    !>  Construct the interpolation of a field from a polynomial expansion to
    !!  discrete reference coordinates.
    !!
    !!  Note: this interpolates to REFERENCE coordinates for the particular element 
    !!  currently being visited. [xi,eta,zeta] in [-1,1]
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !---------------------------------------------------------------------------------------
    function interpolate_field(self,field,ref_nodes) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        real(rk),               intent(in)  :: ref_nodes(:,:)

        type(AD_D), allocatable :: var_gq(:)
        real(rk),   allocatable :: interpolator(:,:) 
        integer(ik)             :: nterms, nnodes, ierr, iterm, eqn_ID, ifield, inode

        !
        ! Construct interpolation matrix
        !
        nterms = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%nterms_s
        nnodes = size(ref_nodes,1)
        allocate(interpolator(nnodes,nterms), stat=ierr)
        if (ierr /= 0) call AllocationError

        do iterm = 1,nterms
            do inode = 1,nnodes
                interpolator(inode,iterm) = polynomial_val(3,nterms,iterm,ref_nodes(inode,1:3))
            end do
        end do

        !
        ! Get access index in solution vector for field being interpolated
        !
        eqn_ID = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%eqn_ID
        ifield = self%prop(eqn_ID)%get_primary_field_index(trim(field))


        !
        ! Call interpolation with interpolator overriding default interpolator
        !
        var_gq = interpolate_element_autodiff(self%mesh,self%solverdata%q,self%element_info,self%function_info,ifield,self%itime,'value',interpolator=interpolator)

    end function interpolate_field
    !***************************************************************************************






    !>  Construct the interpolation of a field from a polynomial expansion to
    !!  discrete physical coordinates.
    !!
    !!  Note: this interpolates to PHYSICAL coordinates, possibly from multiple
    !!  donor elements.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/24/2018
    !!
    !!  @param[in]  field           String indicating primary field to be interpolated.
    !!  @param[in]  physical_nodes  Physical coordinates to be interpolated to.
    !!
    !---------------------------------------------------------------------------------------
    function interpolate_field_general(self,field,physical_nodes,try_offset,donors,donor_nodes,itime) result(var)
        class(chidg_worker_t),  intent(in)              :: self
        character(*),           intent(in)              :: field
        real(rk),               intent(in), optional    :: physical_nodes(:,:)
        real(rk),               intent(in), optional    :: try_offset(3)
        type(element_info_t),   intent(in), optional    :: donors(:)
        real(rk),               intent(in), optional    :: donor_nodes(:,:)
        integer(ik),            intent(in), optional    :: itime

        integer(ik)                             :: eqn_ID, ifield, itime_in
        type(AD_D), allocatable, dimension(:)   :: var

        itime_in = self%itime
        if (present(itime)) itime_in = itime

        ! Get equation_set identifier and locate field index
        eqn_ID = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%eqn_ID
        ifield = self%prop(eqn_ID)%get_primary_field_index(trim(field))

        ! Arbitrary interpolation of primary field onto physical_nodes
        var = interpolate_general_autodiff(self%mesh,                   &
                                           self%solverdata%q,           &
                                           self%function_info,          &
                                           ifield,                      &
                                           itime_in,                    &
                                           'value',                     &
                                           nodes=physical_nodes,        &
                                           try_offset=try_offset,       &
                                           donors=donors,               &
                                           donor_nodes=donor_nodes)

    end function interpolate_field_general
    !**************************************************************************************



    

    !>  Check if a field exists in the cache.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   5/9/2019
    !!
    !--------------------------------------------------------------------------------------
    function check_field_exists(self,field) result(exists)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field

        logical :: exists

        exists = self%cache%check_field_exists(field,'element')

    end function check_field_exists
    !***************************************************************************************






    !>  Return a field from the chidg_cache.
    !!
    !!  Data in the chidg_cache is already interpolated to quadrature nodes.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   7/10/2017
    !!
    !---------------------------------------------------------------------------------------
    function get_field(self,field,interp_type,interp_source_user,iface,override_lift,use_lift_faces,only_lift) result(var_gq)
        class(chidg_worker_t),  intent(in)              :: self
        character(*),           intent(in)              :: field
        character(*),           intent(in)              :: interp_type
        character(*),           intent(in), optional    :: interp_source_user
        integer(ik),            intent(in), optional    :: iface
        logical,                intent(in), optional    :: override_lift
        logical,                intent(in), optional    :: only_lift
        integer(ik),            intent(in), optional    :: use_lift_faces(:)


        type(AD_D),     allocatable :: var_gq(:), tmp_gq(:)
        character(:),   allocatable :: cache_component, cache_type, lift_source, lift_nodes, user_msg, interp_source
        integer(ik)                 :: lift_face_min, lift_face_max, idirection, iface_loop, iface_use, iface_select, i
        real(rk)                    :: stabilization, face_area, centroid_m(3), centroid_p(3), centroid_distance(3),    &
                                       volume_m, volume_p, centroid_normal_distance, average_normals(3)
        real(rk),       allocatable :: unit_normal_1(:), unit_normal_2(:), unit_normal_3(:)
        logical                     :: lift


        !
        ! Get user-specified interpolation source, or get from cache pointer entry
        !
        if (present(interp_source_user)) then
            interp_source = interp_source_user
        else
            interp_source = self%interpolation_source
        end if


        !
        ! Set face interpolation. Default is from worker. 
        ! User can override with 'iface' optional input
        !
        iface_use = self%iface
        if (present(iface)) iface_use = iface


!        !
!        ! Compute adaptive face lift stabilization: NOTE not verified or determined to be stable.
!        !
!        face_area = self%face_area()
!        volume_m   = self%volume('interior')
!        volume_p   = self%volume('exterior')
!        centroid_m = self%centroid('interior')
!        centroid_p = self%centroid('exterior')
!        centroid_distance = abs(centroid_p - centroid_m)
!        unit_normal_1 = self%unit_normal(1)
!        unit_normal_2 = self%unit_normal(2)
!        unit_normal_3 = self%unit_normal(3)
!
!        ! Compute average face normal
!        average_normals(1) = abs(sum(unit_normal_1)/size(unit_normal_1))
!        average_normals(2) = abs(sum(unit_normal_2)/size(unit_normal_2))
!        average_normals(3) = abs(sum(unit_normal_3)/size(unit_normal_3))
!
!        ! Project centroid distance onto face normal vector
!        centroid_normal_distance = abs(centroid_distance(1)*average_normals(1) + centroid_distance(2)*average_normals(2) + centroid_distance(3)*average_normals(3))
!        print*, 'centroid m: ', centroid_m
!        print*, 'centroid p: ', centroid_p
!        print*, 'normal: ', average_normals
!        print*, 'centroid normal: ', centroid_normal_distance
!
!        ! Compute adaptive face stabilization
!        face_lift_stab = (FOUR/(face_area*centroid_normal_distance))*(volume_m * volume_p)/(volume_m + volume_p)
!
!        print*, 'pre comp: ', face_area, volume_m, volume_p, centroid_distance
!        if (self%face_type() == BOUNDARY .and. (trim(interp_source) == 'face interior' .or. trim(interp_source) == 'face exterior')) print*, 'face stab: ', face_lift_stab, self%iface, trim(interp_source)
!        print*, 'face stab: ', face_lift_stab, self%iface, trim(interp_source)
!
!        if (face_lift_stab > 4.5) print*, 'face_lift_stab: ', face_lift_stab
!        if (face_lift_stab < 1.0) print*, 'face_lift_stab: ', face_lift_stab
!
!        if (face_lift_stab < 1.0_rk) face_lift_stab = 1.0_rk



        !
        ! Set cache_component
        !
        select case(trim(interp_source))
            case('face interior') 
                cache_component = 'face interior'
                lift_source     = 'face interior'
                lift_nodes      = 'lift face'
                lift_face_min   = iface_use
                lift_face_max   = iface_use
                stabilization   = face_lift_stab
            !case('face exterior','boundary')
            !    cache_component = 'face exterior'
            !    lift_source     = 'face exterior'
            !    lift_nodes      = 'lift face'
            !    lift_face_min   = iface_use
            !    lift_face_max   = iface_use
            !    stabilization   = real(lift_stab,rk)
            case('boundary')
                cache_component = 'face exterior'
                !lift_source     = 'face interior'
                lift_source     = 'face exterior'
                lift_nodes      = 'lift face'
                lift_face_min   = iface_use
                lift_face_max   = iface_use
                stabilization   = face_lift_stab
            case('face exterior')
                cache_component = 'face exterior'
                lift_source     = 'face exterior'
                lift_nodes      = 'lift face'
                lift_face_min   = iface_use
                lift_face_max   = iface_use
                stabilization   = face_lift_stab
            case('element')
                cache_component = 'element'
                lift_source     = 'face interior'
                lift_nodes      = 'lift element'
                lift_face_min   = 1
                lift_face_max   = NFACES
                !stabilization   = ONE
                stabilization   = elem_lift_stab
            case default
                user_msg = "chidg_worker%get_field: Invalid value for interpolation source. &
                            Try 'face interior', 'face exterior', 'boundary', or 'element'"
                call chidg_signal_three(FATAL,user_msg,trim(field),trim(interp_type),trim(interp_source))
        end select












        !
        ! Set cache_type
        !
        select case(trim(interp_type))
            case('value')
                cache_type = 'value'
                idirection = 0
            case('grad1','gradient1','gradient-1')
                cache_type = 'gradient'
                idirection = 1
            case('grad2','gradient2','gradient-2')
                cache_type = 'gradient'
                idirection = 2
            case('grad3','gradient3','gradient-3')
                cache_type = 'gradient'
                idirection = 3
            case default
                user_msg = "chidg_worker%get_field: Invalid interpolation &
                            type. 'value', 'grad1', 'grad2', 'grad3'"
                call chidg_signal_three(FATAL,user_msg,trim(field),trim(interp_type),present(interp_source_user))
        end select



        !
        ! Determine when we do not want to lift
        !
        ! Do not lift gradient for a boundary state function. Boundary state functions
        ! interpolate from the 'face interior'. Operators interpolate from 'boundary'.
        ! So, if we are on a BOUNDARY face and interpolating from 'face interior', then
        ! we don't want to lift because there is no lift for the boundary function to use
        ! If we aren't on a face, face_type returns NOT_A_FACE, so this is still valid for 
        ! returning element data.
        !do_not_lift = ((self%face_type() == BOUNDARY) .and. (cache_component == 'face interior')) .or. (.not. self%contains_lift) 
        lift = (.not. ((self%face_type() == BOUNDARY) .and. (cache_component == 'face interior'))) .and. &
               (self%contains_lift) .and. &
               (self%cache%lift)

        ! Potential to override lift from optional user input 'override_lift'
        if (present(override_lift)) lift = (.not. override_lift)


        !
        ! Retrieve data from cache
        !
        if ( cache_type == 'value') then
            var_gq = self%cache%get_data(field,cache_component,'value',idirection,self%function_info%seed,iface_use)

        else if (cache_type == 'gradient') then

            if (lift) then
                var_gq = self%cache%get_data(field,cache_component,'gradient',idirection,self%function_info%seed,iface_use)
                ! If we only want lift, zero out primal gradient
                if (present(only_lift)) then
                    if (only_lift) var_gq = ZERO
                end if

                ! Add lift contributions from each face
                if (present(use_lift_faces)) then
                    do iface_loop = 1,size(use_lift_faces)
                        iface_select = use_lift_faces(iface_loop) 
                        tmp_gq = self%cache%get_data(field,lift_source, lift_nodes, idirection, self%function_info%seed,iface_select)
                        var_gq = var_gq + stabilization*tmp_gq
                    end do

                else
                    do iface_loop = lift_face_min,lift_face_max
                        tmp_gq = self%cache%get_data(field,lift_source, lift_nodes, idirection, self%function_info%seed,iface_loop)
                        var_gq = var_gq + stabilization*tmp_gq
                    end do
                end if

            else
                var_gq = self%cache%get_data(field,cache_component,'gradient',idirection,self%function_info%seed,iface_use)
            end if

        else
            user_msg = "chidg_worker%get_field: invalid cache_type."
            call chidg_signal(FATAL,user_msg)

        end if


    end function get_field
    !***************************************************************************************










    !>  Return a model field evaluated at a quadrature node set. The source here
    !!  is determined by chidg_worker.
    !!
    !!  This routine is specifically for model_t's, because we want them to be evaluated
    !!  on face and element sets the same way. So in a model implementation, we just
    !!  want the model to get some quadrature node set to operate on. The chidg_worker
    !!  handles what node set is currently being returned.
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !--------------------------------------------------------------------------------------
    function get_model_field_general(self,field,interp_type) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type

        type(AD_D), allocatable :: var_gq(:)


        if (self%interpolation_source == 'element') then
            var_gq = self%get_model_field_element(field,interp_type) 
        else if (self%interpolation_source == 'face interior') then
            var_gq = self%get_model_field_face(field,interp_type,'face interior')
        else if (self%interpolation_source == 'face exterior') then
            var_gq = self%get_model_field_face(field,interp_type,'face exterior')
        else if (self%interpolation_source == 'boundary') then
            var_gq = self%get_model_field_face(field,interp_type,'boundary')
        end if

    end function get_model_field_general
    !**************************************************************************************










    !>  Return a primary field interpolated to a face quadrature node set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !--------------------------------------------------------------------------------------
    function get_model_field_face(self,field,interp_type,interp_source) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable, dimension(:)   :: var_gq
        character(:),   allocatable                 :: cache_component, cache_type, user_msg
        type(face_info_t)                           :: face_info
        integer(ik)                                 :: idirection, igq



        !
        ! Set cache_component
        !
        if (interp_source == 'face interior') then
            cache_component = 'face interior'
        else if (interp_source == 'face exterior' .or. &
                 interp_source == 'boundary') then
            cache_component = 'face exterior'
        else
            user_msg = "chidg_worker%get_model_field_face: Invalid value for interpolation source. &
                        Try 'face interior', 'face exterior', or 'boundary'"
            call chidg_signal_one(FATAL,user_msg,trim(interp_source))
        end if


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if ( (interp_type == 'grad1')          .or. &
                  (interp_type == 'grad2')          .or. &
                  (interp_type == 'grad3')          .or. &
                  (interp_type == 'grad1 + lift')   .or. &
                  (interp_type == 'grad1+lift'  )   .or. &
                  (interp_type == 'grad2 + lift')   .or. &
                  (interp_type == 'grad2+lift'  )   .or. &
                  (interp_type == 'grad3 + lift')   .or. &
                  (interp_type == 'grad3+lift'  ) ) then
                user_msg = 'chidg_worker%get_model_field_face: Computing gradients for model &
                            fields is not yet implemented.'
                call chidg_signal(FATAL,user_msg)
                                    
        end if



        !
        ! Retrieve data from cache
        !
        var_gq = self%cache%get_data(field,cache_component,cache_type,idirection,self%function_info%seed,self%iface)


    end function get_model_field_face
    !***************************************************************************************












    !>  Return a primary field interpolated to an element quadrature node set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    function get_model_field_element(self,field,interp_type) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type

        type(AD_D),     allocatable, dimension(:) :: var_gq

        type(face_info_t)               :: face_info
        character(:),   allocatable     :: cache_component, cache_type, user_msg
        integer(ik)                     :: idirection, igq, iface


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if ( (interp_type == 'grad1')        .or. &
                  (interp_type == 'grad2')        .or. &
                  (interp_type == 'grad3')        .or. &
                  (interp_type == 'grad1+lift'  ) .or. &
                  (interp_type == 'grad2+lift'  ) .or. &
                  (interp_type == 'grad3+lift'  ) .or. &
                  (interp_type == 'grad1 + lift') .or. &
                  (interp_type == 'grad2 + lift') .or. &
                  (interp_type == 'grad3 + lift') ) then
            user_msg = 'chidg_worker%get_model_field_element: Computing gradients for model &
                        fields is not yet implemented.'
            call chidg_signal(FATAL,user_msg)
        end if




        !
        ! Retrieve data from cache
        !
        var_gq = self%cache%get_data(field,'element',cache_type,idirection,self%function_info%seed)



    end function get_model_field_element
    !****************************************************************************************











    !>  Return an auxiliary field interpolated to a face quadrature node set.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   12/7/2016
    !!
    !!
    !--------------------------------------------------------------------------------------
    function get_auxiliary_field_face(self,field,interp_type,interp_source) result(var_gq_real)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable, dimension(:)   :: var_gq
        real(rk),       allocatable, dimension(:)   :: var_gq_real
        character(:),   allocatable                 :: cache_component, cache_type, user_msg
        type(face_info_t)                           :: face_info
        integer(ik)                                 :: idirection, igq



        !
        ! Set cache_component
        !
        if (interp_source == 'face interior') then
            cache_component = 'face interior'
        else if (interp_source == 'face exterior' .or. &
                 interp_source == 'boundary') then
            cache_component = 'face exterior'
        else
            user_msg = "chidg_worker%get_auxiliary_field_face: Invalid value for interpolation source. &
                        Try 'face interior', 'face exterior', or 'boundary'"
            call chidg_signal_one(FATAL,user_msg,trim(interp_source))
        end if


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (interp_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (interp_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (interp_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3

        else if ( (interp_type == 'grad1+lift'  ) .or. &
                  (interp_type == 'grad2+lift'  ) .or. &
                  (interp_type == 'grad3+lift'  ) .or. &
                  (interp_type == 'grad1 + lift') .or. &
                  (interp_type == 'grad2 + lift') .or. &
                  (interp_type == 'grad3 + lift') ) then
                user_msg = 'chidg_worker%get_auxiliary_field_face: Computing lifted derivatives for auxiliary &
                            fields is not supported.'
                call chidg_signal(FATAL,user_msg)
                                    
        end if



        !
        ! Retrieve data from cache
        !
        var_gq = self%cache%get_data(field,cache_component,cache_type,idirection,self%function_info%seed,self%iface)


        !
        ! Return a real array
        !
        var_gq_real = var_gq(:)%x_ad_


    end function get_auxiliary_field_face
    !***************************************************************************************










    !>  Return an auxiliary field interpolated to an element quadrature node set.
    !!
    !!  NOTE: Returns a real array
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   12/7/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    function get_auxiliary_field_element(self,field,interp_type) result(var_gq_real)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_type

        type(AD_D),     allocatable, dimension(:)   :: var_gq
        real(rk),       allocatable, dimension(:)   :: var_gq_real

        type(face_info_t)               :: face_info
        character(:),   allocatable     :: cache_component, cache_type, user_msg
        integer(ik)                     :: idirection, igq, iface


        !
        ! Set cache_type
        !
        if (interp_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (interp_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (interp_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (interp_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3


        else if ( (interp_type == 'grad1+lift'  ) .or. &
                  (interp_type == 'grad2+lift'  ) .or. &
                  (interp_type == 'grad3+lift'  ) .or. &
                  (interp_type == 'grad1 + lift') .or. &
                  (interp_type == 'grad2 + lift') .or. &
                  (interp_type == 'grad3 + lift') ) then

            user_msg = 'chidg_worker%get_auxiliary_field_element: Computing lifted gradients for auxiliary &
                        fields is not supported.'
            call chidg_signal(FATAL,user_msg)

        end if




        !
        ! Retrieve data from cache
        !
        var_gq = self%cache%get_data(field,'element',cache_type,idirection,self%function_info%seed)



        !
        ! Copy real values to be returned.
        !
        var_gq_real = var_gq(:)%x_ad_


    end function get_auxiliary_field_element
    !****************************************************************************************










    !>  Store a primary field being defined from a boundary condition state function
    !!  to the 'face exterior' cache component.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    subroutine store_bc_state(self,field,cache_data,data_type)
        class(chidg_worker_t),  intent(inout)   :: self
        character(*),           intent(in)      :: field
        type(AD_D),             intent(in)      :: cache_data(:)
        character(*),           intent(in)      :: data_type

        character(:),   allocatable :: cache_type, user_msg
        integer(ik)                 :: idirection


        !
        ! Set cache_type
        !
        if (data_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (data_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (data_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (data_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3
        else
            user_msg = "chidg_worker%store_bc_state: Invalid data_type specification. &
                        Options are 'value', 'grad1', 'grad2', 'grad3'."
            call chidg_signal_one(FATAL,user_msg,trim(data_type))
        end if



        !
        ! Store bc state in cache, face exterior component
        !
        if (cache_type == 'value') then
            call self%cache%set_data(field,'face exterior',cache_data,'value',0,self%function_info%seed,self%iface)

        else if (cache_type == 'gradient') then
            call self%cache%set_data(field,'face exterior',cache_data,'gradient',idirection,self%function_info%seed,self%iface)

        end if


    end subroutine store_bc_state
    !***************************************************************************************










    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    subroutine store_model_field(self,model_field,data_type,cache_data)
        class(chidg_worker_t),  intent(inout)   :: self
        character(*),           intent(in)      :: model_field
        character(*),           intent(in)      :: data_type
        type(AD_D),             intent(in)      :: cache_data(:)

        type(AD_D),     allocatable, dimension(:)   :: field_current, field_update
        character(:),   allocatable :: cache_type, user_msg
        integer(ik)                 :: idirection


        !
        ! Set cache_type
        !
        if (data_type == 'value') then
            cache_type = 'value'
            idirection = 0
        else if (data_type == 'grad1') then
            cache_type = 'gradient'
            idirection = 1
        else if (data_type == 'grad2') then
            cache_type = 'gradient'
            idirection = 2
        else if (data_type == 'grad3') then
            cache_type = 'gradient'
            idirection = 3
        else
            user_msg = "chidg_worker%store_model_field: Invalid data_type specification. &
                        Options are 'value', 'grad1', 'grad2', 'grad3'."
            call chidg_signal_one(FATAL,user_msg,trim(data_type))
        end if



        !
        ! Add data to model field cache
        !
        if (cache_type == 'value') then

            field_update = cache_data

            call self%cache%set_data(model_field,self%interpolation_source,field_update,'value',0,self%function_info%seed,self%iface)

        else if (cache_type == 'gradient') then

            field_update = cache_data

            call self%cache%set_data(model_field,self%interpolation_source,field_update,'gradient',idirection,self%function_info%seed,self%iface)

        end if



    end subroutine store_model_field
    !***************************************************************************************







    !>  Accept fluxes from both sides of a face, apply appropriate transformation
    !!  for potential grid motion, average, dot with face normal vector, and integrate.
    !!
    !!  1: (in)             flux-, flux+
    !!  2: (transform)      flux_ale-, flux_ale+
    !!  3: (average)        flux_avg
    !!  4: (normal flux)    flux_normal
    !!  5: (integrate)      int(flux_normal)
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine integrate_boundary_average(self,primary_field,flux_type,flux_1_m,flux_2_m,flux_3_m,flux_1_p,flux_2_p,flux_3_p)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        character(*),           intent(in)      :: flux_type
        type(AD_D),             intent(inout)   :: flux_1_m(:)
        type(AD_D),             intent(inout)   :: flux_2_m(:)
        type(AD_D),             intent(inout)   :: flux_3_m(:)
        type(AD_D),             intent(inout)   :: flux_1_p(:)
        type(AD_D),             intent(inout)   :: flux_2_p(:)
        type(AD_D),             intent(inout)   :: flux_3_p(:)

        integer(ik)                             :: ifield, idomain_l, ielement_l, eqn_ID
        type(AD_D), allocatable, dimension(:)   :: q_m, q_p, flux_1, flux_2, flux_3, integrand
        type(AD_D), allocatable, dimension(:,:) :: flux_ref_m, flux_ref_p
        real(rk),   allocatable, dimension(:)   :: norm_1, norm_2, norm_3



        !
        ! Compute ALE transformation
        !
        select case(trim(flux_type))
            case('Advection')
                q_m = self%get_primary_field_face(primary_field,'value','face interior')
                q_p = self%get_primary_field_face(primary_field,'value','face exterior')
                flux_ref_m = self%post_process_boundary_advective_flux_ale(flux_1_m,flux_2_m,flux_3_m, advected_quantity=q_m, interp_source='face interior')
                flux_ref_p = self%post_process_boundary_advective_flux_ale(flux_1_p,flux_2_p,flux_3_p, advected_quantity=q_p, interp_source='face exterior')
            case('Diffusion')
                flux_ref_m = self%post_process_boundary_diffusive_flux_ale(flux_1_m,flux_2_m,flux_3_m, interp_source='face interior')
                flux_ref_p = self%post_process_boundary_diffusive_flux_ale(flux_1_p,flux_2_p,flux_3_p, interp_source='face exterior')
            case default
                call chidg_signal_one(FATAL,"worker%integrate_boundary_average: Invalid value for incoming flux_type.",trim(flux_type))
        end select



        !
        ! Compute Average, delay multiplying by HALF until later
        !
        flux_1 = (flux_ref_m(:,1) + flux_ref_p(:,1))
        flux_2 = (flux_ref_m(:,2) + flux_ref_p(:,2))
        flux_3 = (flux_ref_m(:,3) + flux_ref_p(:,3))


        !
        ! Dot with normal vector, complete averaging with HALF
        !
        norm_1 = self%normal(1)
        norm_2 = self%normal(2)
        norm_3 = self%normal(3)
        integrand = HALF*(flux_1*norm_1 + flux_2*norm_2 + flux_3*norm_3)


        !
        ! Integrate
        !
        idomain_l = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID    = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield    = self%prop(eqn_ID)%get_primary_field_index(primary_field)
        call integrate_boundary_scalar_flux(self%mesh,self%solverdata,self%element_info,self%function_info,self%iface,ifield,self%itime,integrand)


    end subroutine integrate_boundary_average
    !****************************************************************************************




    !>  Accept some measure of advection upwind dissipation and integrate.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine integrate_boundary_upwind(self,primary_field,upwind)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        type(AD_D),             intent(inout)   :: upwind(:)

        integer(ik)                                 :: ifield, idomain_l, ielement_l, eqn_ID
        real(rk),   allocatable,    dimension(:)    :: norm_1, norm_2, norm_3, darea

        !
        ! Compute differential areas by computing magnitude of scaled normal vector
        !
        norm_1  = self%normal(1)
        norm_2  = self%normal(2)
        norm_3  = self%normal(3)
        darea = norm_1 ! allocate to avoid DEBUG error
        darea = sqrt(norm_1**TWO+norm_2**TWO+norm_3**TWO)


        !
        ! Multiply by differential area
        !
        upwind = darea*upwind


        !
        ! Integrate
        !
        idomain_l  = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID     = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield     = self%prop(eqn_ID)%get_primary_field_index(primary_field)
        call integrate_boundary_scalar_flux(self%mesh,self%solverdata,self%element_info,self%function_info,self%iface,ifield,self%itime,upwind)


    end subroutine integrate_boundary_upwind
    !****************************************************************************************




    !>  Accept domain boundary flux, transform to ale flux, dot with normal vector, and integrate. 
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !----------------------------------------------------------------------------------------
    subroutine integrate_boundary_condition(self,primary_field,flux_type,flux_1,flux_2,flux_3)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        character(*),           intent(in)      :: flux_type
        type(AD_D),             intent(inout)   :: flux_1(:)
        type(AD_D),             intent(inout)   :: flux_2(:)
        type(AD_D),             intent(inout)   :: flux_3(:)

        integer(ik)                             :: ifield, idomain_l, ielement_l, eqn_ID
        real(rk),   allocatable, dimension(:)   :: norm_1, norm_2, norm_3
        type(AD_D), allocatable, dimension(:)   :: integrand, q_bc
        type(AD_D), allocatable, dimension(:,:) :: flux


        !
        ! Compute ALE transformation
        !
        select case(trim(flux_type))
            case('Advection')
                q_bc = self%get_primary_field_face(primary_field,'value','face interior')
                flux = self%post_process_boundary_advective_flux_ale(flux_1,flux_2,flux_3, advected_quantity=q_bc, interp_source='face interior')
            case('Diffusion')
                flux = self%post_process_boundary_diffusive_flux_ale(flux_1, flux_2, flux_3,'face interior')
            case default
                call chidg_signal_one(FATAL,"worker%integrate_boundary_condition: Invalid value for incoming flux_type.",trim(flux_type))

        end select


        !
        ! Dot flux with normal vector
        !
        norm_1 = self%normal(1)
        norm_2 = self%normal(2)
        norm_3 = self%normal(3)
        integrand = flux(:,1)*norm_1 + flux(:,2)*norm_2 + flux(:,3)*norm_3



        !
        ! Integrate
        !
        idomain_l = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID    = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield    = self%prop(eqn_ID)%get_primary_field_index(primary_field)
        call integrate_boundary_scalar_flux(self%mesh,self%solverdata,self%element_info,self%function_info,self%iface,ifield,self%itime,integrand)


    end subroutine integrate_boundary_condition
    !****************************************************************************************








    !>  Accept a flux at volume quadrature nodes, apply ale transformation, integrate.
    !!
    !!  1: (in)         vec{F}
    !!  2: (transform)  vec{F_ale}
    !!  3: (integrate)  int[ grad(psi) (dot) vec{F_ale} ]dV
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    subroutine integrate_volume_flux(self,primary_field,flux_type,flux_1,flux_2,flux_3)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        character(*),           intent(in)      :: flux_type
        type(AD_D),             intent(inout)   :: flux_1(:)
        type(AD_D),             intent(inout)   :: flux_2(:)
        type(AD_D),             intent(inout)   :: flux_3(:)

        integer(ik)             :: ifield, idomain_l, ielement_l, eqn_ID
        type(AD_D), allocatable :: flux(:,:), q(:)


        idomain_l  = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID     = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield     = self%prop(eqn_ID)%get_primary_field_index(primary_field)


        !
        ! Compute ALE transformation
        !
        select case(trim(flux_type))
            case('Advection')
                q = self%get_primary_field_element(primary_field,'value')
                flux = self%post_process_volume_advective_flux_ale(flux_1,flux_2,flux_3, advected_quantity=q)
            case('Diffusion')
                flux = self%post_process_volume_diffusive_flux_ale(flux_1,flux_2,flux_3)
            case default
                call chidg_signal_one(FATAL,"worker%integrate_volume_flux: Invalid value for incoming flux_type.",trim(flux_type))
        end select

        !
        ! Integrate: int[ grad(psi) (dot) F_ale ]
        !
        call integrate_volume_vector_flux(self%mesh,self%solverdata,self%element_info,self%function_info,ifield,self%itime,flux(:,1),flux(:,2),flux(:,3))


    end subroutine integrate_volume_flux
    !***************************************************************************************





    !>  Accept a source term at element volume quadrature nodes, integrate.
    !!
    !!  Computes integral: int[ psi * S ]dV
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !---------------------------------------------------------------------------------------
    subroutine integrate_volume_source(self,primary_field,integrand)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        type(AD_D),             intent(inout)   :: integrand(:)

        integer(ik) :: ifield, idomain_l, ielement_l, eqn_ID

        idomain_l  = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID     = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield     = self%prop(eqn_ID)%get_primary_field_index(primary_field)

        call integrate_volume_scalar_source(self%mesh,self%solverdata,self%element_info,self%function_info,ifield,self%itime,integrand)

    end subroutine integrate_volume_source
    !***************************************************************************************




    !>  Accumulate residual. No assumed integration steps such as 
    !!  in integrate_volume_flux.
    !!
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/4/2017
    !!
    !--------------------------------------------------------------------------------------
    subroutine accumulate_residual(self,primary_field,residual)
        class(chidg_worker_t),  intent(in)      :: self
        character(*),           intent(in)      :: primary_field
        type(AD_D),             intent(inout)   :: residual(:)

        integer(ik) :: ifield, idomain_l, ielement_l, eqn_ID

        idomain_l = self%element_info%idomain_l
        ielement_l = self%element_info%ielement_l
        eqn_ID    = self%mesh%domain(idomain_l)%elems(ielement_l)%eqn_ID
        ifield    = self%prop(eqn_ID)%get_primary_field_index(primary_field)

        call store_volume_integrals(self%mesh, self%solverdata, self%element_info, self%function_info, ifield, self%itime, residual)

    end subroutine accumulate_residual
    !**************************************************************************************






    !>  Project function from quadrature nodes to modal basis.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/4/2017
    !!
    !--------------------------------------------------------------------------------------
    function project_from_nodes(self,nodes) result(modes)
        class(chidg_worker_t),  intent(in)  :: self
        type(AD_D),             intent(in)  :: nodes(:)

        type(AD_D), allocatable :: temp(:), modes(:)
!        real(rk),   allocatable :: interpolator(:,:)

        associate ( idomain_l  => self%element_info%idomain_l, &
                    ielement_l => self%element_info%ielement_l )
            associate( element => self%mesh%domain(idomain_l)%elems(ielement_l) )

            ! Pre-multiply weights and elemental volumes
            temp = nodes * element%basis_s%weights_element() * element%jinv

            ! Inner product: <psi, f>
            !temp = matmul(transpose(element%basis_s%interpolator_element('Value')),nodes)
            temp = matmul(transpose(element%basis_s%interpolator_element('Value')),temp)
            modes = temp
            
            ! Inner project: <psi, f>/<psi, psi>
!            modes = matmul(element%invmass,temp) 

!            interpolator = element%basis_s%interpolator_element('Value')
!            modes = matmul(inv(interpolator(1:size(interpolator,2),:)), nodes)

            end associate
        end associate

    end function project_from_nodes
    !**************************************************************************************








    !>  Return outward-facing, 'scaled' normal vector.
    !!
    !!  Normal vector scaled by face differential area. One can compute face differential 
    !!  areas by computing the magnitude of this normal vector.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !---------------------------------------------------------------------------------------
    function normal(self,direction) result(norm_gq)
        class(chidg_worker_t),  intent(in)  :: self
        integer(ik),            intent(in)  :: direction

        real(rk), dimension(:), allocatable :: norm_gq

        norm_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%norm(:,direction)

    end function normal
    !***************************************************************************************









    !>  Return outward-facing unit normal vector on the undeformed face.
    !!
    !!  Magnitude of this vector is 1.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !---------------------------------------------------------------------------------------
    function unit_normal(self,direction,iface_override) result(unorm_gq)
        class(chidg_worker_t),  intent(in)              :: self
        integer(ik),            intent(in)              :: direction
        integer(ik),            intent(in), optional    :: iface_override

        real(rk), dimension(:), allocatable :: unorm_gq

        if (present(iface_override)) then
            unorm_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,iface_override)%unorm(:,direction)
        else
            unorm_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%unorm(:,direction)
        end if

    end function unit_normal
    !***************************************************************************************



    !>  Return outward-facing unit normal vector on the ALE deformed face.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !---------------------------------------------------------------------------------------
    function unit_normal_ale(self,direction) result(unorm_gq)
        class(chidg_worker_t),  intent(in)  :: self
        integer(ik),            intent(in)  :: direction

        real(rk), dimension(:), allocatable :: unorm_gq

        unorm_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%unorm_def(:,direction)

    end function unit_normal_ale
    !***************************************************************************************





    !>  Return physical coordinates at the support nodes.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !!
    !---------------------------------------------------------------------------------------
    function coords(self) result(coords_)
        class(chidg_worker_t),  intent(in)  :: self

        type(point_t), allocatable, dimension(:) :: coords_(:)

        coords_ = point_t(self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def)

    end function coords
    !***************************************************************************************








    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function x(self,source) result(x_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        real(rk), dimension(:), allocatable :: x_gq

        if (source == 'boundary') then
            x_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,1)
        else if (source == 'volume') then
            x_gq = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,1)
        else
            call chidg_signal(FATAL,"chidg_worker%x(source): Invalid value for 'source'. Options are 'boundary', 'volume'")
        end if



    end function x
    !**************************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function y(self,source) result(y_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        real(rk), dimension(:), allocatable :: y_gq


        if (source == 'boundary') then
            y_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,2)
        else if (source == 'volume') then
            y_gq = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,2)
        else
            call chidg_signal(FATAL,"chidg_worker%y(source): Invalid value for 'source'. Options are 'boundary', 'volume'")
        end if



    end function y
    !**************************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function z(self,source) result(z_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        real(rk), dimension(:), allocatable :: z_gq

        if (source == 'boundary') then
            z_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,3)
        else if (source == 'volume') then
            z_gq = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,3)
        else
            call chidg_signal(FATAL,"chidg_worker%z(source): Invalid value for 'source'. Options are 'boundary', 'volume'")
        end if


    end function z
    !**************************************************************************************








    !>  Interface for returning coordinates.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   02/16/2017
    !!
    !!
    !--------------------------------------------------------------------------------------
    function coordinate(self,string,user_source) result(coords)
        class(chidg_worker_t),  intent(in)              :: self
        character(*),           intent(in)              :: string
        character(*),           intent(in), optional    :: user_source


        character(:),   allocatable                 :: user_msg, source
        real(rk),       allocatable, dimension(:)   :: gq_1, gq_2, gq_3, coords


        !
        ! Select source
        !
        if ( present(user_source) ) then
            source = user_source
        else
            source = self%interpolation_source
        end if


        !
        ! Get coordinates
        !
        if ( (source == 'boundary') .or. (source == 'face interior') .or. (source == 'face exterior') ) then
            gq_1 = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,1)
            gq_2 = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,2)
            gq_3 = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%interp_coords_def(:,3)
        else if ( (source == 'volume') .or. (source == 'element') ) then
            gq_1 = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,1)
            gq_2 = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,2)
            gq_3 = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_def(:,3)
        else
            user_msg = "chidg_worker%coordinate: Invalid source for returning coordinate. Options are 'boundary' and 'volume'."
            call chidg_signal_one(FATAL,user_msg,source)
        end if




        !
        ! Define coordinate to return.
        !
        select case (string)
            case ('1')
                coords = gq_1
            case ('2')
                coords = gq_2
            case ('3')
                coords = gq_3

            
!            case ('x')
!
!            case ('y')
!
!            case ('r')
!
!            case ('theta')
!
!            case ('z')
!
            case default
                call chidg_signal_one(FATAL,"chidg_worker%coordinate: Invalid string for selecting coordinate.",string)
        end select


    end function coordinate
    !**************************************************************************************





    !>  Interface for returning coordinates.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   02/16/2017
    !!
    !!
    !--------------------------------------------------------------------------------------
    function coordinate_arbitrary(self,ref_coords) result(phys_coords)
        class(chidg_worker_t),  intent(in)              :: self
        real(rk),               intent(in)              :: ref_coords(:,:)

        real(rk)    :: phys_coords(size(ref_coords,1),size(ref_coords,2))
        integer     :: i

        do i = 1,size(ref_coords,1)
            phys_coords(i,:) = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%physical_point([ref_coords(i,1),ref_coords(i,2),ref_coords(i,3)],'Deformed')
        end do

    end function coordinate_arbitrary
    !**************************************************************************************














    !>  Return the approximate size of an element bounding box.
    !!
    !!  Returns:
    !!      h(3) = [hx, hy, hz]
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/31/2017
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function element_size(self,source) result(h)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        integer(ik) :: ineighbor_domain_l, ineighbor_element_l
        real(rk)    :: h(3)
        logical     :: proc_local, chimera_face


        if (source == 'interior') then

            h = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%h

        else if (source == 'exterior') then

            !
            ! If Chimera face, use interior element size. APPROXIMATION
            !
            chimera_face = (self%face_type() == CHIMERA)
            if (chimera_face) then

                h = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%h

            !
            ! If conforming face, check for processor status of neighbor.
            !
            else

                proc_local = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_proc  ==  IRANK)
                if (proc_local) then

                    ineighbor_domain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_domain_l
                    ineighbor_element_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_element_l
                    h = self%mesh%domain(ineighbor_domain_l)%elems(ineighbor_element_l)%h

                else

                    h = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%neighbor_h

                end if

            end if


        else
            call chidg_signal(FATAL,"chidg_worker%element_size(source): Invalid value for 'source'. Options are 'interior', 'exterior'")
        end if


    end function element_size
    !**************************************************************************************








    !>  Return the order of the solution polynomial expansion.
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/31/2017
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function solution_order(self,source) result(order)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        integer(ik) :: ineighbor_domain_l, ineighbor_element_l, nterms_s, order
        logical     :: proc_local, chimera_face


        if (source == 'interior') then

            nterms_s = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%nterms_s


        else if (source == 'exterior') then

            !
            ! If Chimera face, use interior element order. APPROXIMATION
            !
            chimera_face = (self%face_type() == CHIMERA)
            if (chimera_face) then

                nterms_s = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%nterms_s

            !
            ! If conforming face, check for processor status of neighbor.
            !
            else

                proc_local = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_proc  ==  IRANK)
                if (proc_local) then

                    ineighbor_domain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_domain_l
                    ineighbor_element_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_element_l
                    nterms_s = self%mesh%domain(ineighbor_domain_l)%elems(ineighbor_element_l)%nterms_s

                else

                    nterms_s = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_nterms_s

                end if

            end if


        else
            call chidg_signal(FATAL,"chidg_worker%solution_order(source): Invalid value for 'source'. Options are 'interior', 'exterior'")
        end if




        !
        ! Compute polynomial order from number of terms in the expansion. 
        !
        ! ASSUMES TENSOR PRODUCT BASIS
        !
        order = nint( real(nterms_s,rk)**(THIRD) - ONE)

    end function solution_order
    !**************************************************************************************






    !>
    !!
    !! @author  Eric M. Wolf
    !! @date    03/01/2019 
    !!
    !--------------------------------------------------------------------------------
    function h_smooth(self,user_source) result(h_s)
        class(chidg_worker_t),  intent(in)              :: self
        character(*),           intent(in), optional    :: user_source

        character(:),   allocatable                 :: user_msg, source
        real(rk),       allocatable, dimension(:,:) :: h_s

        ! Select source
        source = self%interpolation_source
        if ( present(user_source) ) source = user_source

        ! Retrieve smoothed h-field
        if ( (source == 'boundary') .or. (source == 'face interior') .or. (source == 'face exterior') ) then
            h_s = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%h_smooth
        else if ( (source == 'volume') .or. (source == 'element') ) then
            h_s = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%h_smooth
        else
            user_msg = "chidg_worker%h_smooth: Invalid source for returning smooth h field. Options are 'boundary' and 'volume'."
            call chidg_signal_one(FATAL,user_msg,source)
        end if

    end function h_smooth 
    !**************************************************************************************






    !>  Return the quadrature weights for integration.
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/31/2017
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function quadrature_weights(self,source) result(weights)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        real(rk),   allocatable,    dimension(:)    :: weights

        if (source == 'face') then
            weights = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%basis_s%weights_face(self%iface)
        else if (source == 'element') then
            weights = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%basis_s%weights_element()
        else
            call chidg_signal(FATAL,"chidg_worker%quadrature_weights(source): Invalid value for 'source'. Options are 'face', 'element'")
        end if


    end function quadrature_weights
    !**************************************************************************************








    !>  Return the inverse jacobian mapping for integration.
    !!
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/31/2017
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function inverse_jacobian(self,source) result(jinv)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        real(rk),   allocatable,    dimension(:)    :: jinv

        if (source == 'face') then
            jinv = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%jinv
        else if (source == 'element') then
            jinv = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%jinv
        else
            call chidg_signal(FATAL,"chidg_worker%inverse_jacobian(source): Invalid value for 'source'. Options are 'face', 'element'")
        end if


    end function inverse_jacobian
    !**************************************************************************************


    !>  Return the volume of the interior/exterior element.
    !!
    !!  NOTE: this returns the volume of the reference physical element, not the deformed
    !!  ALE volume.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   06/30/2019
    !!
    !!
    !--------------------------------------------------------------------------------------
    function volume(self,source) result(volume_)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        integer(ik) :: idomain_l, ielement_l, pelem_ID
        real(rk)    :: volume_

        if (trim(source) == 'interior') then
            volume_ = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%vol

        else if (trim(source) == 'exterior') then

            ! Interior face, find neighbor and account for local or parallel storage
            if (self%face_type() == INTERIOR) then
                idomain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
                ielement_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
                pelem_ID   = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_pelem_ID
                if (pelem_ID == NO_ID) then
                    volume_ = self%mesh%domain(idomain_l)%elems(ielement_l)%vol
                else
                    volume_ = self%mesh%parallel_element(pelem_ID)%vol
                end if

            ! Boundary face, assume ficticious exterior element of equal volume
            else if (self%face_type() == BOUNDARY) then
                volume_ = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%vol

            ! Overset face, assume ficticious exterior element of equal volume
            else if (self%face_type() == CHIMERA) then
                volume_ = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%vol

            end if



        else
            call chidg_signal(FATAL,"chidg_worker%volume: invalid source parameter. Valid inputs are ['interior', 'exterior']")
        end if

    end function volume
    !**************************************************************************************








    !>  Return the centroid of the interior/exterior element.
    !!
    !!  NOTE: this returns the centroid of the reference physical element, not the deformed
    !!  ALE centroid.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   06/30/2019
    !!
    !--------------------------------------------------------------------------------------
    function centroid(self,source) result(centroid_)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: source

        integer(ik) :: idomain_l, ielement_l, pelem_ID
        real(rk)    :: centroid_(3), face_centroid(3), interior_centroid(3), delta(3)

        if (trim(source) == 'interior') then
             centroid_ = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%centroid

        else if (trim(source) == 'exterior') then

            ! Interior face, find neighbor and account for local or parallel storage
            if (self%face_type() == INTERIOR) then
                idomain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
                ielement_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
                pelem_ID   = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_pelem_ID
                if (pelem_ID == NO_ID) then
                    centroid_ = self%mesh%domain(idomain_l)%elems(ielement_l)%centroid
                else
                    centroid_ = self%mesh%parallel_element(pelem_ID)%centroid
                end if

            ! Boundary face, assume ficticious exterior element and assume centroid at equal 
            ! distance to face opposite interior element
            else if (self%face_type() == BOUNDARY) then
                face_centroid = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%centroid
                interior_centroid = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%centroid
                delta = face_centroid - interior_centroid
                centroid_ = interior_centroid + TWO*delta

            ! Overset face, assume ficticious exterior element and assume centroid at equal 
            ! distance to face opposite interior element
            else if (self%face_type() == CHIMERA) then
                face_centroid = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%centroid
                interior_centroid = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%centroid
                delta = face_centroid - interior_centroid
                centroid_ = interior_centroid + TWO*delta

            end if



        else
            call chidg_signal(FATAL,"chidg_worker%centroid: invalid source parameter. Valid inputs are ['interior', 'exterior']")
        end if

    end function centroid 
    !**************************************************************************************









    !>  Return the area of the current face.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   01/31/2017
    !!
    !!
    !--------------------------------------------------------------------------------------
    function face_area(self) result(area)
        class(chidg_worker_t),  intent(in)  :: self

        real(rk)    :: area

        area = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%total_area

    end function face_area
    !**************************************************************************************








    !>  Return the coordinate system of the current geometric object.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   02/15/2017
    !!
    !!
    !--------------------------------------------------------------------------------------
    function coordinate_system(self) result(system)
        class(chidg_worker_t),  intent(in)  :: self

        character(:),   allocatable :: system

        if (self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%coordinate_system == CARTESIAN) then
            system = 'Cartesian'
        else if (self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%coordinate_system == CYLINDRICAL) then
            system = 'Cylindrical'
        end if

    end function coordinate_system
    !**************************************************************************************




    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !!
    !--------------------------------------------------------------------------------------
    function face_type(self) result(face_type_)
        class(chidg_worker_t),  intent(in)  :: self

        integer(ik) :: idom, ielem, iface
        integer(ik) :: face_type_

        idom  = self%element_info%idomain_l
        ielem = self%element_info%ielement_l
        iface = self%iface

        if ( (iface >= 1) .and. (iface <= NFACES) ) then
            face_type_ = self%mesh%domain(idom)%faces(ielem,iface)%ftype
        else
            face_type_ = NOT_A_FACE
        end if


    end function face_type
    !**************************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/22/2016
    !!
    !!
    !!
    !--------------------------------------------------------------------------------------
    function time(self) result(solution_time)
        class(chidg_worker_t),  intent(in)  :: self

        real(rk) :: solution_time

        solution_time = self%t

    end function time
    !**************************************************************************************





    !>  Given a 3D quadrature node set, compute the number of nodes in one dimension
    !!  of the set.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/4/2017
    !!
    !-------------------------------------------------------------------------------------
    function nnodes1d(self,node_set_3d) result(nnodes1d_)
        class(chidg_worker_t),  intent(in)  :: self
        class(*),               intent(in)  :: node_set_3d(:)

        integer(ik) :: nnodes1d_

        nnodes1d_ = 0
        do while ( nnodes1d_*nnodes1d_*nnodes1d_  < size(node_set_3d) )
            nnodes1d_ = nnodes1d_ + 1
        end do

    end function nnodes1d
    !*************************************************************************************






    !>
    !!
    !! @author  Eric M. Wolf
    !! @date    03/20/2019 
    !!
    !--------------------------------------------------------------------------------
    function get_octree_rbf_indices(self, rbf_set_ID) result(rbf_index_list)
        class(chidg_worker_t),  intent(inout)   :: self
        integer(ik),            intent(in)      :: rbf_set_ID

        integer(ik) :: idomain_l, ielement_l
        integer(ik), allocatable, dimension(:) :: rbf_index_list

        idomain_l  = self%element_info%idomain_l 
        ielement_l = self%element_info%ielement_l 

        rbf_index_list = self%mesh%domain(idomain_l)%elems(ielement_l)%get_rbf_indices(rbf_set_ID)

    end function get_octree_rbf_indices
    !********************************************************************************



    !> This function adapts and simplifies get_ndepend_exterior from type_cache_handler, 
    !! which asks for extra arguments we might not have access to.
    !! 
    !!
    !! @author  Eric M. Wolf
    !! @date    03/14/2019 
    !!
    !--------------------------------------------------------------------------------
    function get_ndepend_simple(self, iface) result(ndepend)
        class(chidg_worker_t),  intent(in)   :: self 
        integer(ik),            intent(in)   :: iface

        integer(ik) :: ndepend, idomain_l, ielement_l,  &
                       ChiID, group_ID, patch_ID, face_ID

        idomain_l  = self%element_info%idomain_l 
        ielement_l = self%element_info%ielement_l 

        ! Compute the number of exterior element dependencies for face exterior state
        if ( self%face_type() == INTERIOR ) then
            ndepend = 1
            
        else if ( self%face_type() == CHIMERA ) then
            ChiID   = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%ChiID
            ndepend = self%mesh%domain(idomain_l)%chimera%recv(ChiID)%ndonors()

        else if ( self%face_type() == BOUNDARY ) then
            group_ID = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
            patch_ID = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
            face_ID  = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID
            ndepend  = self%mesh%bc_patch_group(group_ID)%patch(patch_ID)%ncoupled_elements(face_ID)

        end if

    end function get_ndepend_simple
    !****************************************************************************************





    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/8/2016
    !!
    !-------------------------------------------------------------------------------------
    subroutine destructor(self)
        type(chidg_worker_t),   intent(inout)   :: self

        if (associated(self%mesh))       nullify(self%mesh)
        if (associated(self%solverdata)) nullify(self%solverdata)
        if (associated(self%cache))      nullify(self%cache)

    end subroutine destructor
    !*************************************************************************************


    !
    ! ALE Procedures
    !


    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date 8/10/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_area_ratio(self) result(res)
        class(chidg_worker_t),  intent(in)  :: self

        integer(ik)                             :: idomain_l, ielement_l, iface
        real(rk),   dimension(:),   allocatable :: res

        res = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ale_area_ratio

    end function get_area_ratio
    !****************************************************************************************************





    ! Get ALE quantities
    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_grid_velocity_element(self) result(grid_vel_gq)
        class(chidg_worker_t),  intent(in)  :: self

        real(rk), dimension(:,:), allocatable :: grid_vel_gq

        grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%interp_coords_vel

    end function get_grid_velocity_element
    !****************************************************************************************************









!    !>
!    !!
!    !!  @author Eric M. Wolf
!    !!  @date 1/9/2017
!    !!
!    !----------------------------------------------------------------------------------------------------
!    function get_grid_velocity_face(self,field,interp_source) result(grid_vel_comp_gq)
!        class(chidg_worker_t),  intent(in)  :: self
!        character(*),           intent(in)  :: field
!        character(*),           intent(in)  :: interp_source
!
!
!        real(rk),   dimension(:),   allocatable :: grid_vel_comp_gq
!        real(rk),   dimension(:,:), allocatable :: grid_vel_gq
!        integer(ik)                             :: idomain_l, ielement_l, iface
!        logical                                 :: parallel_neighbor
!
!        ! Presumably, the node velocity
!        if ((interp_source == 'face interior') .or. (interp_source == 'boundary')) then
!            grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%interp_coords_vel
!
!        else if (interp_source == 'face exterior') then
!
!            if (self%face_type() == INTERIOR) then
!                parallel_neighbor = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_proc /= IRANK) 
!                if (parallel_neighbor) then
!                    grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%neighbor_interp_coords_vel
!                else
!                    idomain_l   = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
!                    ielement_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
!                    iface       = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_face
!                    grid_vel_gq = self%mesh%domain(idomain_l)%faces(ielement_l, iface)%interp_coords_vel
!                end if
!
!
!            else if (self%face_type() == CHIMERA) then
!                ! For Chimera faces, we actually just want to use the interior face velocity
!                grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%interp_coords_vel
!
!            else if (self%face_type() == BOUNDARY) then
!                grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%interp_coords_vel
!            end if
!        else
!                call chidg_signal(FATAL,"chidg_worker%get_grid_velocity_face: Invalid value for 'interp_source'.")
!        end if
!
!        if (field == 'u_grid') then
!            grid_vel_comp_gq = grid_vel_gq(:,1)
!        else if (field == 'v_grid') then
!            grid_vel_comp_gq = grid_vel_gq(:,2)
!        else if (field == 'w_grid') then
!            grid_vel_comp_gq = grid_vel_gq(:,3)
!        else
!            call chidg_signal(FATAL,"chidg_worker%get_grid_velocity_face: Invalid value for 'field'.")
!        end if
!
!    end function get_grid_velocity_face
!    !****************************************************************************************************







    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_grid_velocity_face(self,interp_source) result(grid_vel_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: interp_source


        real(rk),   dimension(:,:), allocatable :: grid_vel_gq
        integer(ik)                             :: idomain_l, ielement_l, iface
        logical                                 :: parallel_neighbor


        if (self%face_type() == INTERIOR .and. interp_source == 'face exterior') then
            parallel_neighbor = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_proc /= IRANK) 
            if (parallel_neighbor) then
                grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%neighbor_interp_coords_vel
            else
                idomain_l   = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
                ielement_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
                iface       = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_face
                grid_vel_gq = self%mesh%domain(idomain_l)%faces(ielement_l, iface)%interp_coords_vel
            end if

        else
            ! For all other cases, use the 'face interior' grid velocity
            grid_vel_gq = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%interp_coords_vel
        end if

    end function get_grid_velocity_face
    !****************************************************************************************************













    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_inv_jacobian_grid_element(self) result(jacobian_grid_gq)
        class(chidg_worker_t),  intent(in)  :: self

        real(rk), dimension(:,:,:), allocatable :: jacobian_grid_gq

        jacobian_grid_gq = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%ale_Dinv(:,:,:)

    end function get_inv_jacobian_grid_element
    !****************************************************************************************************







    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_inv_jacobian_grid_face(self,interp_source) result(ale_Dinv)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: interp_source

        real(rk), dimension(:,:,:), allocatable :: ale_Dinv
        integer(ik) :: ChiID, idomain_l, ielement_l, iface
        logical     :: parallel_neighbor


        if ((interp_source == 'face interior') .or. (interp_source == 'boundary')) then
            ale_Dinv = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ale_Dinv


        else if (interp_source == 'face exterior') then

            if (self%face_type() == INTERIOR) then
                parallel_neighbor = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_proc /= IRANK) 
                if (parallel_neighbor) then
                    ale_Dinv = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%neighbor_ale_Dinv
                else
                    idomain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
                    ielement_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
                    iface      = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_face
                    ale_Dinv = self%mesh%domain(idomain_l)%faces(ielement_l, iface)%ale_Dinv
                end if

            else if (self%face_type() == CHIMERA) then
                ChiID = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ChiID
                ale_Dinv = self%mesh%domain(self%element_info%idomain_l)%chimera%recv(ChiID)%ale_Dinv

            else if (self%face_type() == BOUNDARY) then
                 ale_Dinv = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ale_Dinv
            end if

        else
            call chidg_signal(FATAL,"chidg_worker%get_inv_jacobian_grid_face: Invalid value for 'interp_source'.")
        end if


    end function get_inv_jacobian_grid_face
    !****************************************************************************************************


    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_det_jacobian_grid_element(self,interp_type) result(vals)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: interp_type


        real(rk), dimension(:), allocatable :: vals

        ! Interpolate modes to nodes
        if (interp_type == 'value') then
            vals = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%ale_g
        else if (interp_type == 'grad1') then
            vals = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%ale_g_grad1
        else if (interp_type == 'grad2') then
            vals = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%ale_g_grad2
        else if (interp_type == 'grad3') then
            vals = self%mesh%domain(self%element_info%idomain_l)%elems(self%element_info%ielement_l)%ale_g_grad3
        else
            call chidg_signal(FATAL,"worker%get_det_jacobian_grid_element: invalid selection for returning det_jacobian_grid.")
        end if

    end function get_det_jacobian_grid_element
    !****************************************************************************************************



    !>
    !!
    !!  @author Eric M. Wolf
    !!  @date 1/9/2017
    !!
    !----------------------------------------------------------------------------------------------------
    function get_det_jacobian_grid_face(self, interp_type,interp_source) result(vals)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: interp_type
        character(*),           intent(in)  :: interp_source

        real(rk), dimension(:), allocatable :: vals
        logical                             :: parallel_neighbor
        integer(ik) :: ChiID, idomain_l, ielement_l, iface


        if ( (trim(interp_type) /= 'value') .and. &
             (trim(interp_type) /= 'grad1') .and. &
             (trim(interp_type) /= 'grad2') .and. &
             (trim(interp_type) /= 'grad3') ) call chidg_signal_one(FATAL,"chidg_worker%get_det_jacobian_grid_face: invalid interp_type.",trim(interp_type))

        if ( (trim(interp_source) /= 'face interior') .and. &
             (trim(interp_source) /= 'face exterior') .and. &
             (trim(interp_source) /= 'boundary') ) call chidg_signal_one(FATAL,"chidg_worker%get_det_jacobian_grid_face: invalid interp_type.",trim(interp_type))


        ! Interpolate modes to nodes
        if ((interp_source == 'face interior') .or. (interp_source == 'boundary') )then

            if (interp_type == 'value') then
                vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g
            else if (interp_type == 'grad1') then
                vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad1
            else if (interp_type == 'grad2') then
                vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad2
            else if (interp_type == 'grad3') then
                vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad3
            end if


        else if (interp_source == 'face exterior') then

            if (self%face_type() == INTERIOR) then
                parallel_neighbor = (self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ineighbor_proc /= IRANK)
                if (parallel_neighbor) then
                    if (interp_type == 'value') then
                        vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%neighbor_ale_g
                    else if (interp_type == 'grad1') then
                        vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%neighbor_ale_g_grad1
                    else if (interp_type == 'grad2') then
                        vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%neighbor_ale_g_grad2
                    else if (interp_type == 'grad3') then
                        vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%neighbor_ale_g_grad3
                    end if
                else
                    idomain_l  = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_domain_l
                    ielement_l = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_element_l
                    iface      = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ineighbor_face
                    if (interp_type == 'value') then
                        vals = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%ale_g
                    else if (interp_type == 'grad1') then
                        vals = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%ale_g_grad1
                    else if (interp_type == 'grad2') then
                        vals = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%ale_g_grad2
                    else if (interp_type == 'grad3') then
                        vals = self%mesh%domain(idomain_l)%faces(ielement_l,iface)%ale_g_grad3
                    end if
                end if



            else if (self%face_type() == CHIMERA) then
                ChiID = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l, self%iface)%ChiID
                if (interp_type == 'value') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%chimera%recv(ChiID)%ale_g
                else if (interp_type == 'grad1') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%chimera%recv(ChiID)%ale_g_grad1
                else if (interp_type == 'grad2') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%chimera%recv(ChiID)%ale_g_grad2
                else if (interp_type == 'grad3') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%chimera%recv(ChiID)%ale_g_grad3
                end if


            else if (self%face_type() == BOUNDARY) then
                if (interp_type == 'value') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g
                else if (interp_type == 'grad1') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad1
                else if (interp_type == 'grad2') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad2
                else if (interp_type == 'grad3') then
                    vals = self%mesh%domain(self%element_info%idomain_l)%faces(self%element_info%ielement_l,self%iface)%ale_g_grad3
                end if

            end if

        else

            call chidg_signal_one(FATAL,"chidg_worker%get_det_jacobian_grid_face: Invalid value for 'interp_source'.", trim(interp_source))
        end if


    end function get_det_jacobian_grid_face
    !****************************************************************************************************



    !
    ! ALE reference to physical variable conversions
    !

    !>  Return a primary field evaluated at a quadrature node set. The source here
    !!  is determined by chidg_worker.
    !!
    !!  This routine is specifically for model_t's, because we want them to be evaluated
    !!  on face and element sets the same way. So in a model implementation, we just
    !!  want the model to get some quadrature node set to operate on. The chidg_worker
    !!  handles what node set is currently being returned.
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !--------------------------------------------------------------------------------------
    function get_primary_field_value_ale_general(self,field) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field

        type(AD_D), allocatable :: var_gq(:)


        if (self%interpolation_source == 'element') then
            var_gq = self%get_primary_field_value_ale_element(field) 
        else if (self%interpolation_source == 'face interior') then
            var_gq = self%get_primary_field_value_ale_face(field,'face interior')
        else if (self%interpolation_source == 'face exterior') then
            var_gq = self%get_primary_field_value_ale_face(field,'face exterior')
        else if (self%interpolation_source == 'boundary') then
            var_gq = self%get_primary_field_value_ale_face(field,'boundary')
        end if

    end function get_primary_field_value_ale_general
    !**************************************************************************************

    !>  Return a primary field evaluated at a quadrature node set. The source here
    !!  is determined by chidg_worker.
    !!
    !!  This routine is specifically for model_t's, because we want them to be evaluated
    !!  on face and element sets the same way. So in a model implementation, we just
    !!  want the model to get some quadrature node set to operate on. The chidg_worker
    !!  handles what node set is currently being returned.
    !!  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   11/30/2016
    !!
    !--------------------------------------------------------------------------------------
    function get_primary_field_grad_ale_general(self,field,gradient_type) result(var_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: gradient_type

        type(AD_D), allocatable :: var_gq(:,:)

        

        if (self%interpolation_source == 'element') then
            var_gq = self%get_primary_field_grad_ale_element(field,gradient_type) 
        else if (self%interpolation_source == 'face interior') then
            var_gq = self%get_primary_field_grad_ale_face(field,gradient_type,'face interior')
        else if (self%interpolation_source == 'face exterior') then
            var_gq = self%get_primary_field_grad_ale_face(field,gradient_type,'face exterior')
        else if (self%interpolation_source == 'boundary') then
            var_gq = self%get_primary_field_grad_ale_face(field,gradient_type,'boundary')
        end if

    end function get_primary_field_grad_ale_general
    !**************************************************************************************





    !>  Returns physical space quantities by tranforming from the reference configuration.
    !!
    !!
    !!  @author Eric M. Wolf
    !!  @date 7/6/2017
    !!
    !!
    !----------------------------------------------------------------------------------------------------
    function get_primary_field_value_ale_element(self, field) result(val_gq)
        class(chidg_worker_t), intent(in)           :: self
        character(*), intent(in)                    :: field

        type(AD_D), allocatable                     :: val_ref(:), val_gq(:)
        real(rk), allocatable                       :: ale_g(:)

!        val_ref = self%get_primary_field_element(field, 'value')
!        ale_g   = self%get_det_jacobian_grid_element('value')
!
!        val_gq = (val_ref/ale_g)

        val_gq = self%get_primary_field_element(field, 'value')

    end function get_primary_field_value_ale_element
    !****************************************************************************************************





    
    !>  Returns physical space quantities by tranforming from the reference configuration.
    !!
    !!
    !!  @author Eric M. Wolf
    !!  @date 7/6/2017
    !!
    !!
    !----------------------------------------------------------------------------------------------------
    function get_primary_field_grad_ale_element(self, field, gradient_type) result(grad_u_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: gradient_type

        type(AD_D),     allocatable :: u(:), grad1_u(:), grad2_u(:), grad3_u(:), grad_u_gq(:,:)
        real(rk),       allocatable :: ale_g(:),        &
                                       ale_g_grad1(:),  &
                                       ale_g_grad2(:),  &
                                       ale_g_grad3(:),  &
                                       ale_Dinv(:,:,:)

        character(:),   allocatable :: user_msg


        if (gradient_type == 'gradient + lift') then
            grad1_u = self%get_primary_field_element(field,'grad1 + lift')
            grad2_u = self%get_primary_field_element(field,'grad2 + lift')
            grad3_u = self%get_primary_field_element(field,'grad3 + lift')
        elseif (gradient_type == 'gradient') then
            grad1_u = self%get_primary_field_element(field,'grad1')
            grad2_u = self%get_primary_field_element(field,'grad2')
            grad3_u = self%get_primary_field_element(field,'grad3')
        else
            user_msg = "chidg_worker%get_primary_field_grad_ale_element: Invalid interpolation &
                        type. 'gradient' or 'gradient + lift'"
            call chidg_signal(FATAL,user_msg)
        end if


        allocate(grad_u_gq(size(grad1_u,1),3))
        grad_u_gq(:,1) = grad1_u
        grad_u_gq(:,2) = grad2_u
        grad_u_gq(:,3) = grad3_u


    end function get_primary_field_grad_ale_element
    !************************************************************************************







    !>  Returns physical space quantities by tranforming from the reference configuration.
    !!
    !!
    !!  @author Eric M. Wolf
    !!  @date 7/6/2017
    !!
    !!
    !------------------------------------------------------------------------------------
    function get_primary_field_value_ale_face(self, field, interp_source) result(val_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: interp_source

        type(AD_D), allocatable :: val_ref(:), val_gq(:), g_bar(:)
        real(rk),   allocatable :: ale_g(:)

!        val_ref = self%get_primary_field_face(field, 'value', interp_source)
!        if (interp_source == 'boundary') then
!            ! In this case, the value supplied by the BC is already the physical value!
!            val_gq = val_ref
!
!        else
!            ! Otherwise, we need to convert the reference configuration value to the physical value.
!            ale_g  = self%get_det_jacobian_grid_face('value', interp_source)
!            val_gq = (val_ref/ale_g)
!
!        end if

        val_gq = self%get_primary_field_face(field, 'value', interp_source)


    end function get_primary_field_value_ale_face
    !************************************************************************************

    






    !>  Returns physical space quantities by tranforming from the reference configuration.
    !!
    !!
    !!  @author Eric M. Wolf
    !!  @date 7/6/2017
    !!
    !!
    !------------------------------------------------------------------------------------
    function get_primary_field_grad_ale_face(self, field, gradient_type, interp_source) result(grad_u_gq)
        class(chidg_worker_t),  intent(in)  :: self
        character(*),           intent(in)  :: field
        character(*),           intent(in)  :: gradient_type
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable :: u(:), grad1_u(:), grad2_u(:), grad3_u(:), grad_u_gq(:,:)
        real(rk),       allocatable :: ale_g(:),        &
                                       ale_g_grad1(:),  &
                                       ale_g_grad2(:),  &
                                       ale_g_grad3(:),  &
                                       ale_Dinv(:,:,:)
        character(:),   allocatable :: user_msg

!        if (gradient_type == 'gradient + lift') then
!            grad1_u = self%get_primary_field_face(field,'grad1 + lift', interp_source)
!            grad2_u = self%get_primary_field_face(field,'grad2 + lift', interp_source)
!            grad3_u = self%get_primary_field_face(field,'grad3 + lift', interp_source)
!        elseif (gradient_type == 'gradient') then
!            grad1_u = self%get_primary_field_face(field,'grad1', interp_source)
!            grad2_u = self%get_primary_field_face(field,'grad2', interp_source)
!            grad3_u = self%get_primary_field_face(field,'grad3', interp_source)
!        else
!            user_msg = "chidg_worker%get_primary_field_grad_ale_face: Invalid interpolation &
!                        type. 'gradient' or 'gradient + lift'"
!            call chidg_signal(FATAL,user_msg)
!        end if
!
!
!
!        allocate(grad_u_gq(size(grad1_u,1),3))
!        if (interp_source == 'boundary') then
!            ! In this case, the value supplied by the BC is already the physical value!
!            grad_u_gq(:,1) = grad1_u
!            grad_u_gq(:,2) = grad2_u
!            grad_u_gq(:,3) = grad3_u
!
!        else
!            ! Otherwise, we need to convert the reference configuration value to the physical value.
!            ale_g       = self%get_det_jacobian_grid_face('value', interp_source)
!            ale_g_grad1 = self%get_det_jacobian_grid_face('grad1', interp_source)
!            ale_g_grad2 = self%get_det_jacobian_grid_face('grad2', interp_source)
!            ale_g_grad3 = self%get_det_jacobian_grid_face('grad3', interp_source)
!            ale_Dinv    = self%get_inv_jacobian_grid_face(interp_source)
!
!            u = self%get_primary_field_face(field,'value', interp_source)
!
!            grad1_u = grad1_u-(u/ale_g)*ale_g_grad1
!            grad2_u = grad2_u-(u/ale_g)*ale_g_grad2
!            grad3_u = grad3_u-(u/ale_g)*ale_g_grad3
!
!            grad_u_gq(:,1) = (ale_Dinv(1,1,:)*grad1_u + ale_Dinv(2,1,:)*grad2_u + ale_Dinv(3,1,:)*grad3_u)/ale_g
!            grad_u_gq(:,2) = (ale_Dinv(1,2,:)*grad1_u + ale_Dinv(2,2,:)*grad2_u + ale_Dinv(3,2,:)*grad3_u)/ale_g
!            grad_u_gq(:,3) = (ale_Dinv(1,3,:)*grad1_u + ale_Dinv(2,3,:)*grad2_u + ale_Dinv(3,3,:)*grad3_u)/ale_g
!
!        end if





        if (gradient_type == 'gradient + lift') then
            grad1_u = self%get_primary_field_face(field,'grad1 + lift', interp_source)
            grad2_u = self%get_primary_field_face(field,'grad2 + lift', interp_source)
            grad3_u = self%get_primary_field_face(field,'grad3 + lift', interp_source)
        elseif (gradient_type == 'gradient') then
            grad1_u = self%get_primary_field_face(field,'grad1', interp_source)
            grad2_u = self%get_primary_field_face(field,'grad2', interp_source)
            grad3_u = self%get_primary_field_face(field,'grad3', interp_source)
        else
            user_msg = "chidg_worker%get_primary_field_grad_ale_face: Invalid interpolation &
                        type. 'gradient' or 'gradient + lift'"
            call chidg_signal(FATAL,user_msg)
        end if


        allocate(grad_u_gq(size(grad1_u,1),3))
        grad_u_gq(:,1) = grad1_u
        grad_u_gq(:,2) = grad2_u
        grad_u_gq(:,3) = grad3_u


    end function get_primary_field_grad_ale_face
    !************************************************************************************



    !
    ! ALE flux post-processing
    !

    !>
    !!
    !!  @author Eric Wolf (AFRL)
    !!
    !!
    !------------------------------------------------------------------------------------
    function post_process_volume_advective_flux_ale(self, flux_1, flux_2, flux_3, advected_quantity) result(flux_ref)
        class(chidg_worker_t),  intent(in)  :: self
        type(AD_D),             intent(in)  :: flux_1(:)
        type(AD_D),             intent(in)  :: flux_2(:)
        type(AD_D),             intent(in)  :: flux_3(:)
        type(AD_D),             intent(in)  :: advected_quantity(:)

        type(AD_D), allocatable, dimension(:)   :: flux_1_tmp, flux_2_tmp, flux_3_tmp
        type(AD_D), allocatable, dimension(:,:) :: flux_ref
        real(rk),   allocatable                 :: ale_g(:), ale_Dinv(:,:,:), grid_vel(:,:)


        grid_vel = self%get_grid_velocity_element()
        ale_g    = self%get_det_jacobian_grid_element('value')
        ale_Dinv = self%get_inv_jacobian_grid_element()

        flux_1_tmp = flux_1-grid_vel(:,1)*advected_quantity
        flux_2_tmp = flux_2-grid_vel(:,2)*advected_quantity
        flux_3_tmp = flux_3-grid_vel(:,3)*advected_quantity
       
        allocate(flux_ref(size(flux_1,1),3))
        flux_ref(:,1) = ale_g*(ale_Dinv(1,1,:)*flux_1_tmp + ale_Dinv(1,2,:)*flux_2_tmp + ale_Dinv(1,3,:)*flux_3_tmp)
        flux_ref(:,2) = ale_g*(ale_Dinv(2,1,:)*flux_1_tmp + ale_Dinv(2,2,:)*flux_2_tmp + ale_Dinv(2,3,:)*flux_3_tmp)
        flux_ref(:,3) = ale_g*(ale_Dinv(3,1,:)*flux_1_tmp + ale_Dinv(3,2,:)*flux_2_tmp + ale_Dinv(3,3,:)*flux_3_tmp)


    end function post_process_volume_advective_flux_ale
    !************************************************************************************






    !>
    !!
    !!  @author Eric Wolf (AFRL)
    !!
    !!
    !------------------------------------------------------------------------------------
    function post_process_boundary_advective_flux_ale(self, flux_1, flux_2, flux_3, advected_quantity, interp_source) result(flux_ref)
        class(chidg_worker_t),  intent(in)  :: self
        type(AD_D),             intent(in)  :: flux_1(:)
        type(AD_D),             intent(in)  :: flux_2(:)
        type(AD_D),             intent(in)  :: flux_3(:)
        type(AD_D),             intent(in)  :: advected_quantity(:)
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable, dimension(:)   :: flux_1_tmp, flux_2_tmp, flux_3_tmp
        type(AD_D),     allocatable                 :: flux_ref(:,:)
        real(rk),       allocatable                 :: ale_g(:), ale_Dinv(:,:,:), grid_vel(:,:)
        character(:),   allocatable                 :: source
        logical                                     :: chimera_face


!        chimera_face = (self%face_type() == CHIMERA)
!        if (chimera_face) then
!            source = 'face interior'
!        else
!            source = interp_source
!        end if
        source = interp_source


        grid_vel = self%get_grid_velocity_face(source)
        ale_g    = self%get_det_jacobian_grid_face('value', source)
        ale_Dinv = self%get_inv_jacobian_grid_face(source)


        flux_1_tmp = flux_1-grid_vel(:,1)*advected_quantity
        flux_2_tmp = flux_2-grid_vel(:,2)*advected_quantity
        flux_3_tmp = flux_3-grid_vel(:,3)*advected_quantity
       
        allocate(flux_ref(size(flux_1,1),3))
        flux_ref(:,1) = ale_g*(ale_Dinv(1,1,:)*flux_1_tmp + ale_Dinv(1,2,:)*flux_2_tmp + ale_Dinv(1,3,:)*flux_3_tmp)
        flux_ref(:,2) = ale_g*(ale_Dinv(2,1,:)*flux_1_tmp + ale_Dinv(2,2,:)*flux_2_tmp + ale_Dinv(2,3,:)*flux_3_tmp)
        flux_ref(:,3) = ale_g*(ale_Dinv(3,1,:)*flux_1_tmp + ale_Dinv(3,2,:)*flux_2_tmp + ale_Dinv(3,3,:)*flux_3_tmp)


    end function post_process_boundary_advective_flux_ale
    !************************************************************************************






    
    !>
    !!
    !!  @author Eric Wolf (AFRL)
    !!
    !!
    !------------------------------------------------------------------------------------
    function post_process_volume_diffusive_flux_ale(self, flux_1, flux_2, flux_3) result(flux_ref)
        class(chidg_worker_t),  intent(in)  :: self
        type(AD_D),             intent(in)  :: flux_1(:)
        type(AD_D),             intent(in)  :: flux_2(:)
        type(AD_D),             intent(in)  :: flux_3(:)


        type(AD_D), allocatable :: flux_ref(:,:)
        real(rk),   allocatable :: ale_g(:), ale_Dinv(:,:,:)


        ale_g    = self%get_det_jacobian_grid_element('value')
        ale_Dinv = self%get_inv_jacobian_grid_element()

       
        allocate(flux_ref(size(flux_1,1),3))
        flux_ref(:,1) = ale_g*(ale_Dinv(1,1,:)*flux_1 + ale_Dinv(1,2,:)*flux_2 + ale_Dinv(1,3,:)*flux_3)
        flux_ref(:,2) = ale_g*(ale_Dinv(2,1,:)*flux_1 + ale_Dinv(2,2,:)*flux_2 + ale_Dinv(2,3,:)*flux_3)
        flux_ref(:,3) = ale_g*(ale_Dinv(3,1,:)*flux_1 + ale_Dinv(3,2,:)*flux_2 + ale_Dinv(3,3,:)*flux_3)


    end function post_process_volume_diffusive_flux_ale
    !************************************************************************************





    !>
    !!
    !!  @author Eric Wolf (AFRL)
    !!
    !!
    !------------------------------------------------------------------------------------
    function post_process_boundary_diffusive_flux_ale(self, flux_1, flux_2, flux_3, interp_source) result(flux_ref)
        class(chidg_worker_t),  intent(in)  :: self
        type(AD_D),             intent(in)  :: flux_1(:)
        type(AD_D),             intent(in)  :: flux_2(:)
        type(AD_D),             intent(in)  :: flux_3(:)
        character(*),           intent(in)  :: interp_source

        type(AD_D),     allocatable :: flux_ref(:,:)
        real(rk),       allocatable :: ale_g(:), ale_Dinv(:,:,:)
        character(:),   allocatable :: source
        logical                     :: chimera_face

!        chimera_face = (self%face_type() == CHIMERA)
!        if (chimera_face) then
!            source = 'face interior'
!        else
!            source = interp_source
!        end if
        source = interp_source

        ale_g    = self%get_det_jacobian_grid_face('value', source)
        ale_Dinv = self%get_inv_jacobian_grid_face(source)

       
        allocate(flux_ref(size(flux_1,1),3))
        flux_ref(:,1) = ale_g*(ale_Dinv(1,1,:)*flux_1 + ale_Dinv(1,2,:)*flux_2 + ale_Dinv(1,3,:)*flux_3)
        flux_ref(:,2) = ale_g*(ale_Dinv(2,1,:)*flux_1 + ale_Dinv(2,2,:)*flux_2 + ale_Dinv(2,3,:)*flux_3)
        flux_ref(:,3) = ale_g*(ale_Dinv(3,1,:)*flux_1 + ale_Dinv(3,2,:)*flux_2 + ale_Dinv(3,3,:)*flux_3)


    end function post_process_boundary_diffusive_flux_ale
    !************************************************************************************






    !>
    !!
    !! @author  Eric M. Wolf
    !! @date    04/16/2019 
    !!
    !--------------------------------------------------------------------------------
    function get_pressure_jump_indicator(self) result(val_gq)
        class(chidg_worker_t),      intent(inout)  :: self

        type(AD_D), allocatable :: val_gq(:)
        type(AD_D), allocatable :: nodal_ones(:), pressure_p(:), pressure_m(:), jump(:), avg(:)
        type(AD_D)              :: face_val

        real(rk),   allocatable :: jinv(:), weight(:)

        integer(ik)     :: iface, order, iface_old
        real(rk)        :: phi_min, phi_max

        nodal_ones = self%get_field('Density', 'value', 'element')
        nodal_ones = ONE
        val_gq = ZERO*nodal_ones     

        iface_old = self%iface

        ! Loop over faces
        do iface = 1, NFACES
            call self%set_face(iface)
        ! Get face internal/external pressure values
            pressure_m = self%get_field('Pressure','value','face interior')
            pressure_p = self%get_field('Pressure','value','face exterior')

            jump = (pressure_p-pressure_m)
            avg  = HALF*(pressure_p+pressure_m)

            ! Integrate over face
            jinv   = self%inverse_jacobian('face')
            weight = self%quadrature_weights('face')
            face_val = sum(jinv*weight*abs(jump/avg))/sum(jinv*weight) 

            ! Add to sum
            val_gq = val_gq + face_val*nodal_ones   

        end do !iface

        ! Reset original face index
        call self%set_face(iface_old)

    end function get_pressure_jump_indicator
    !********************************************************************************



    !>
    !! 
    !!
    !! @author  Eric M. Wolf
    !! @date    04/16/2019 
    !!
    !--------------------------------------------------------------------------------
    function get_pressure_jump_shock_sensor(self) result(sensor)
        class(chidg_worker_t),      intent(inout)  :: self

        type(AD_D), allocatable :: sensor(:)
        type(AD_D), allocatable :: jump_indicator(:), logval(:)

        integer(ik) :: order
        real(rk)    :: phi_min, phi_max

        jump_indicator = self%get_pressure_jump_indicator()

        logval = log10(jump_indicator)

        order = self%solution_order('interior')
        phi_min = -2.0_rk - log10(real(order+1, rk))
        phi_max = phi_min + 1.0_rk

        sensor = sin_ramp(logval, phi_min, phi_max)

    end function get_pressure_jump_shock_sensor
    !********************************************************************************


































end module type_chidg_worker
