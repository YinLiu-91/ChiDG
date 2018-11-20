!>  Boundary condition module
!!      - contains instantiations of all boundary condition for dynamically creating boundary conditions at run-time
!!      
!!
!!  Registering boundary conditions
!!      - To register a boundary condition:
!!          1st: Import it's definition for use in the current module
!!          2nd: In the 'register_bcs' routine, declare an instance of the boundary condition
!!          3rd: In the 'register_bcs' routine, push an instanace of the bc to the registered_bcs vector 
!!
!--------------------------------------------------------
module mod_bc
#include <messenger.h>
    use mod_kinds,          only: rk,ik
    use type_bc_state,      only: bc_state_t
    use type_bcvector,      only: bcvector_t

    !
    ! Import boundary conditions
    !
    use bc_empty,                               only: empty_t
    use bc_periodic,                            only: periodic_t

    ! Scalar boundary conditions
    use bc_state_linearadvection_extrapolate,   only: linearadvection_extrapolate_t
    use bc_state_scalar_value,                  only: scalar_value_t
    use bc_state_scalar_derivative,             only: scalar_derivative_t
    use bc_state_scalar_extrapolate,            only: scalar_extrapolate_t
    use bc_state_gcl_extrapolate,               only: gcl_extrapolate_t
    use bc_state_gcl_wall,                      only: gcl_wall_t
    use bc_state_gcl_farfield,                  only: gcl_farfield_t
    use bc_state_gcl_symmetry,                  only: gcl_symmetry_t
    
    ! Dual Scalar boundary conditions
    use bc_state_dual_scalar_value,                  only: dual_scalar_value_t
    use bc_state_dual_scalar_extrapolate,            only: dual_scalar_extrapolate_t

    ! Mesh motion boundary conditions
    use bc_state_mesh_motion_value,                  only: mesh_motion_value_t
    use bc_state_mesh_motion_derivative,             only: mesh_motion_derivative_t
    use bc_state_mesh_motion_extrapolate,            only: mesh_motion_extrapolate_t


    ! Fluid boundary conditions
    use bc_state_wall,                              only: wall_t
    use bc_state_moving_wall,                       only: moving_wall_t
    use bc_state_inlet_total,                       only: inlet_total_t
    use bc_state_inlet_characteristic,              only: inlet_characteristic_t
    use bc_state_outlet_constant_pressure,          only: outlet_constant_pressure_t
    use bc_state_outlet_linear_pressure,            only: outlet_linear_pressure_t
    use bc_state_outlet_auxiliary_equations,        only: outlet_auxiliary_equations_t
    use bc_state_outlet_neumann_pressure_fd,        only: outlet_neumann_pressure_fd_t
    use bc_state_outlet_neumann_pressure_localdg,   only: outlet_neumann_pressure_localdg_t
    use bc_state_outlet_neumann_pressure_localdg_new,   only: outlet_neumann_pressure_localdg_new_t
    use bc_state_outlet_neumann_pressure_globaldg,  only: outlet_neumann_pressure_globaldg_t
    use bc_state_outlet_neumann_LODI_localdg,       only: outlet_neumann_LODI_localdg_t
    !use bc_state_outlet_point_pressure,         only: outlet_point_pressure_t
    !use bc_state_outlet_LODI_pressure,          only: outlet_LODI_pressure_t
    !use bc_state_outlet_LODI_z_pressure,        only: outlet_LODI_z_pressure_t
    !use bc_state_outlet_wukie,                  only: outlet_wukie_t
    use bc_state_outlet_steady_1dchar,              only: outlet_steady_1dchar_t
    use bc_state_outlet_3dgiles,                    only: outlet_3dgiles_t
    use bc_state_outlet_3dgiles_innerproduct,       only: outlet_3dgiles_innerproduct_t
    use bc_state_outlet_giles_quasi3d_steady,       only: outlet_giles_quasi3d_steady_t
    use bc_state_outlet_giles_quasi3d_unsteady_HB,  only: outlet_giles_quasi3d_unsteady_HB_t
    use bc_state_inlet_giles_quasi3d_unsteady_HB,   only: inlet_giles_quasi3d_unsteady_HB_t
    use bc_state_turbo_interface_steady,            only: turbo_interface_steady_t
    use bc_state_fluid_extrapolate,                 only: fluid_extrapolate_t
    use bc_state_momentum_inlet,                    only: momentum_inlet_t
    use bc_state_symmetry,                          only: symmetry_t
    use bc_state_slipwall,                          only: slipwall_t
    use bc_state_farfield,                          only: farfield_t
    use bc_state_farfield_perturbation,             only: farfield_perturbation_t

    use bc_state_outlet_nrbc_lindblad,          only: outlet_nrbc_lindblad_t
    use bc_state_inlet_nrbc_lindblad,           only: inlet_nrbc_lindblad_t
    use bc_state_outlet_nrbc_giles,             only: outlet_nrbc_giles_t
    use bc_state_inlet_nrbc_giles,              only: inlet_nrbc_giles_t

    ! Turbulence boundary conditions
    use bc_state_spalart_allmaras_inlet,            only: spalart_allmaras_inlet_t
    use bc_state_spalart_allmaras_outlet,           only: spalart_allmaras_outlet_t
    use bc_state_spalart_allmaras_symmetry,         only: spalart_allmaras_symmetry_t
    use bc_state_spalart_allmaras_farfield,         only: spalart_allmaras_farfield_t
    use bc_state_spalart_allmaras_wall,             only: spalart_allmaras_wall_t
    use bc_state_spalart_allmaras_interface_steady, only: spalart_allmaras_interface_steady_t

    ! Artificial Viscosity boundary conditions
    use bc_state_artificial_viscosity_wall,     only: artificial_viscosity_wall_t
    use bc_state_artificial_viscosity_inlet,    only: artificial_viscosity_inlet_t
    use bc_state_artificial_viscosity_outlet,   only: artificial_viscosity_outlet_t
    use bc_state_artificial_viscosity_symmetry, only: artificial_viscosity_symmetry_t

    ! Radial-Angular equilibrium
    use bc_state_rae_extrapolate,   only: rae_extrapolate_t
    use bc_state_rae_dirichlet,     only: rae_dirichlet_t

    ! Radial-Angular equilibrium
    use bc_state_rac_extrapolate,   only: rac_extrapolate_t
    use bc_state_rac_dirichlet,     only: rac_dirichlet_t

    ! Radial-Angular equilibrium
    use bc_state_tm_extrapolate,   only: tm_extrapolate_t
    use bc_state_tm_dirichlet,     only: tm_dirichlet_t

    use bc_state_graddemo_gradp_extrapolate,        only: graddemo_gradp_extrapolate_t
    use bc_state_graddemo_gradp_extrapolate_outer,  only: graddemo_gradp_extrapolate_outer_t

    use bc_state_auxiliary_boundary,        only: auxiliary_boundary_t
    use bc_state_auxiliary_interior,        only: auxiliary_interior_t

    use bc_state_pgradtest_extrapolate,    only: pgradtest_extrapolate_t


    ! Linearized Euler Eigen
    use bc_primlineuler_extrapolate,    only: primlineuler_extrapolate_t
    use bc_primlineuler_wall,           only: primlineuler_wall_t

    ! Hyperbolized Poisson
    use bc_state_HP_wall,               only: HP_wall_t
    use bc_state_HP_extrapolate,        only: HP_extrapolate_t
    implicit none


    !
    ! Global vector of registered boundary conditions
    !
    type(bcvector_t)    :: registered_bcs
    logical             :: initialized = .false.

contains


    !>  Register boundary conditions in a module vector.
    !!
    !!  This allows the available boundary conditions to be queried in the same way that they 
    !!  are registered for allocation. 
    !!
    !!  This gets called by chidg%init('env')
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2016
    !!
    !!
    !--------------------------------------------------------------------------------------------
    subroutine register_bcs()
        integer :: nbcs, ibc

        !
        ! Instantiate bcs
        !
        type(empty_t)                           :: EMPTY
        type(periodic_t)                        :: PERIODIC
        type(linearadvection_extrapolate_t)     :: LINEARADVECTION_EXTRAPOLATE
        type(scalar_value_t)                    :: SCALAR_VALUE
        type(scalar_derivative_t)               :: SCALAR_DERIVATIVE
        type(scalar_extrapolate_t)              :: SCALAR_EXTRAPOLATE
        type(gcl_extrapolate_t)                 :: GCL_EXTRAPOLATE
        type(gcl_wall_t)                        :: GCL_WALL
        type(gcl_farfield_t)                    :: GCL_FARFIELD
        type(gcl_symmetry_t)                    :: GCL_SYMMETRY
        
        type(dual_scalar_value_t)               :: DUAL_SCALAR_VALUE
        type(dual_scalar_extrapolate_t)         :: DUAL_SCALAR_EXTRAPOLATE

        type(mesh_motion_value_t)               :: MESH_MOTION_VALUE
        type(mesh_motion_derivative_t)          :: MESH_MOTION_DERIVATIVE
        type(mesh_motion_extrapolate_t)         :: MESH_MOTION_EXTRAPOLATE


        type(wall_t)                            :: WALL
        type(moving_wall_t)                     :: MOVING_WALL
        type(inlet_total_t)                     :: INLET_TOTAL
        type(inlet_characteristic_t)            :: INLET_CHARACTERISTIC
        type(outlet_constant_pressure_t)        :: OUTLET_CONSTANT_PRESSURE
        type(outlet_linear_pressure_t)          :: OUTLET_LINEAR_PRESSURE
        type(outlet_auxiliary_equations_t)      :: OUTLET_AUXILIARY_EQUATIONS
        type(outlet_neumann_pressure_fd_t)      :: OUTLET_NEUMANN_PRESSURE_FD
        type(outlet_neumann_pressure_localdg_t) :: OUTLET_NEUMANN_PRESSURE_LOCALDG
        type(outlet_neumann_pressure_localdg_new_t) :: OUTLET_NEUMANN_PRESSURE_LOCALDG_NEW
        type(outlet_neumann_pressure_globaldg_t):: OUTLET_NEUMANN_PRESSURE_GLOBALDG
        type(outlet_neumann_LODI_localdg_t)     :: OUTLET_NEUMANN_LODI_LOCALDG
        !type(outlet_point_pressure_t)           :: OUTLET_POINT_PRESSURE
        !type(outlet_LODI_pressure_t)            :: OUTLET_LODI_PRESSURE
        !type(outlet_LODI_z_pressure_t)          :: OUTLET_LODI_Z_PRESSURE
        !type(outlet_wukie_t)                    :: OUTLET_WUKIE
        type(outlet_steady_1dchar_t)            :: OUTLET_STEADY_1DCHAR
        type(outlet_3dgiles_t)                  :: OUTLET_3DGILES
        type(outlet_3dgiles_innerproduct_t)     :: OUTLET_3DGILES_INNERPRODUCT
        type(outlet_giles_quasi3d_steady_t)     :: OUTLET_GILES_QUASI3D_STEADY
        type(outlet_giles_quasi3d_unsteady_HB_t):: OUTLET_GILES_QUASI3D_UNSTEADY_HB
        type(inlet_giles_quasi3d_unsteady_HB_t) :: INLET_GILES_QUASI3D_UNSTEADY_HB
        type(turbo_interface_steady_t)          :: TURBO_INTERFACE_STEADY
        type(fluid_extrapolate_t)               :: FLUID_EXTRAPOLATE
        type(momentum_inlet_t)                  :: MOMENTUM_INLET
        type(symmetry_t)                        :: SYMMETRY
        type(slipwall_t)                        :: SLIP_WALL
        type(farfield_t)                        :: FARFIELD
        type(farfield_perturbation_t)           :: FARFIELD_PERTURBATION

        type(outlet_nrbc_lindblad_t)    ::  outlet_nrbc_lindblad
        type(outlet_nrbc_giles_t)       ::  outlet_nrbc_giles
        type(inlet_nrbc_lindblad_t)     ::  inlet_nrbc_lindblad
        type(inlet_nrbc_giles_t)        ::  inlet_nrbc_giles

        type(spalart_allmaras_inlet_t)              :: SPALART_ALLMARAS_INLET
        type(spalart_allmaras_outlet_t)             :: SPALART_ALLMARAS_OUTLET
        type(spalart_allmaras_symmetry_t)           :: SPALART_ALLMARAS_SYMMETRY
        type(spalart_allmaras_farfield_t)           :: SPALART_ALLMARAS_FARFIELD
        type(spalart_allmaras_wall_t)               :: SPALART_ALLMARAS_WALL
        type(spalart_allmaras_interface_steady_t)   :: SPALART_ALLMARAS_INTERFACE_STEADY

        type(artificial_viscosity_wall_t)       :: ARTIFICIAL_VISCOSITY_WALL
        type(artificial_viscosity_inlet_t)      :: ARTIFICIAL_VISCOSITY_INLET
        type(artificial_viscosity_outlet_t)     :: ARTIFICIAL_VISCOSITY_OUTLET
        type(artificial_viscosity_symmetry_t)   :: ARTIFICIAL_VISCOSITY_SYMMETRY

        ! Radial-Angular Equilibirum
        type(rae_extrapolate_t) :: RAE_EXTRAPOLATE
        type(rae_dirichlet_t)   :: RAE_DIRICHLET

        ! Radial-Angular Equilibirum
        type(rac_extrapolate_t) :: RAC_EXTRAPOLATE
        type(rac_dirichlet_t)   :: RAC_DIRICHLET

        ! Tangential Equilibirum
        type(tm_extrapolate_t) :: TM_EXTRAPOLATE
        type(tm_dirichlet_t)   :: TM_DIRICHLET

        type(graddemo_gradp_extrapolate_t)          :: GRADDEMO_GRADP_EXTRAPOLATE
        type(graddemo_gradp_extrapolate_outer_t)    :: GRADDEMO_GRADP_EXTRAPOLATE_OUTER

        type(auxiliary_boundary_t)      :: AUXILIARY_BOUNDARY
        type(auxiliary_interior_t)      :: AUXILIARY_INTERIOR

        type(pgradtest_extrapolate_t)  :: PGRADTEST_EXTRAPOLATE

        ! Linearized Euler Eign
        type(primlineuler_extrapolate_t)    :: PRIMLINEULER_EXTRAPOLATE
        type(primlineuler_wall_t)           :: PRIMLINEULER_WALL

        ! Hyperbolized Poisson
        type(HP_wall_t)                     :: HP_WALL
        type(HP_extrapolate_t)              :: HP_EXTRAPOLATE

        if ( .not. initialized ) then
            !
            ! Register in global vector
            !
            call registered_bcs%push_back(EMPTY)
            call registered_bcs%push_back(PERIODIC)

            call registered_bcs%push_back(LINEARADVECTION_EXTRAPOLATE)
            call registered_bcs%push_back(SCALAR_VALUE)
            call registered_bcs%push_back(SCALAR_DERIVATIVE)
            call registered_bcs%push_back(SCALAR_EXTRAPOLATE)
            call registered_bcs%push_back(GCL_EXTRAPOLATE)
            call registered_bcs%push_back(GCL_WALL)
            call registered_bcs%push_back(GCL_FARFIELD)
            call registered_bcs%push_back(GCL_SYMMETRY)
            
            call registered_bcs%push_back(DUAL_SCALAR_VALUE)
            call registered_bcs%push_back(DUAL_SCALAR_EXTRAPOLATE)

            call registered_bcs%push_back(MESH_MOTION_VALUE)
            call registered_bcs%push_back(MESH_MOTION_DERIVATIVE)
            call registered_bcs%push_back(MESH_MOTION_EXTRAPOLATE)


            call registered_bcs%push_back(WALL)
            call registered_bcs%push_back(MOVING_WALL)
            call registered_bcs%push_back(INLET_TOTAL)
            call registered_bcs%push_back(INLET_CHARACTERISTIC)
            call registered_bcs%push_back(OUTLET_CONSTANT_PRESSURE)
            call registered_bcs%push_back(OUTLET_LINEAR_PRESSURE)
            call registered_bcs%push_back(OUTLET_AUXILIARY_EQUATIONS)
            call registered_bcs%push_back(OUTLET_NEUMANN_PRESSURE_FD)
            call registered_bcs%push_back(OUTLET_NEUMANN_PRESSURE_LOCALDG)
            call registered_bcs%push_back(OUTLET_NEUMANN_PRESSURE_LOCALDG_NEW)
            call registered_bcs%push_back(OUTLET_NEUMANN_PRESSURE_GLOBALDG)
            call registered_bcs%push_back(OUTLET_NEUMANN_LODI_LOCALDG)
            call registered_bcs%push_back(OUTLET_STEADY_1DCHAR)
            call registered_bcs%push_back(OUTLET_3DGILES)
            call registered_bcs%push_back(OUTLET_3DGILES_INNERPRODUCT)
            call registered_bcs%push_back(OUTLET_GILES_QUASI3D_STEADY)
            call registered_bcs%push_back(OUTLET_GILES_QUASI3D_UNSTEADY_HB)
            call registered_bcs%push_back(INLET_GILES_QUASI3D_UNSTEADY_HB)
            call registered_bcs%push_back(TURBO_INTERFACE_STEADY)
            !call registered_bcs%push_back(OUTLET_POINT_PRESSURE)
            !call registered_bcs%push_back(OUTLET_LODI_PRESSURE)
            !call registered_bcs%push_back(OUTLET_LODI_Z_PRESSURE)
            !call registered_bcs%push_back(OUTLET_WUKIE)
            call registered_bcs%push_back(FLUID_EXTRAPOLATE)
            call registered_bcs%push_back(MOMENTUM_INLET)
            call registered_bcs%push_back(SYMMETRY)
            call registered_bcs%push_back(SLIP_WALL)
            call registered_bcs%push_back(FARFIELD)
            call registered_bcs%push_back(FARFIELD_PERTURBATION)

            call registered_bcs%push_back(OUTLET_NRBC_LINDBLAD)
            call registered_bcs%push_back(OUTLET_NRBC_GILES)
            call registered_bcs%push_back(INLET_NRBC_LINDBLAD)
            call registered_bcs%push_back(INLET_NRBC_GILES)

            call registered_bcs%push_back(SPALART_ALLMARAS_INLET)
            call registered_bcs%push_back(SPALART_ALLMARAS_OUTLET)
            call registered_bcs%push_back(SPALART_ALLMARAS_SYMMETRY)
            call registered_bcs%push_back(SPALART_ALLMARAS_FARFIELD)
            call registered_bcs%push_back(SPALART_ALLMARAS_WALL)
            call registered_bcs%push_back(SPALART_ALLMARAS_INTERFACE_STEADY)

            call registered_bcs%push_back(ARTIFICIAL_VISCOSITY_WALL)
            call registered_bcs%push_back(ARTIFICIAL_VISCOSITY_INLET)
            call registered_bcs%push_back(ARTIFICIAL_VISCOSITY_OUTLET)
            call registered_bcs%push_back(ARTIFICIAL_VISCOSITY_SYMMETRY)

            call registered_bcs%push_back(RAE_EXTRAPOLATE)
            call registered_bcs%push_back(RAE_DIRICHLET)

            call registered_bcs%push_back(RAC_EXTRAPOLATE)
            call registered_bcs%push_back(RAC_DIRICHLET)

            call registered_bcs%push_back(TM_EXTRAPOLATE)
            call registered_bcs%push_back(TM_DIRICHLET)

            call registered_bcs%push_back(GRADDEMO_GRADP_EXTRAPOLATE)
            call registered_bcs%push_back(GRADDEMO_GRADP_EXTRAPOLATE_OUTER)

            call registered_bcs%push_back(AUXILIARY_BOUNDARY)
            call registered_bcs%push_back(AUXILIARY_INTERIOR)

            call registered_bcs%push_back(PGRADTEST_EXTRAPOLATE)

            call registered_bcs%push_back(PRIMLINEULER_EXTRAPOLATE)
            call registered_bcs%push_back(PRIMLINEULER_WALL)

            call registered_bcs%push_back(HP_WALL)
            call registered_bcs%push_back(HP_EXTRAPOLATE)


            !
            ! Initialize each boundary condition in set. Doesn't need modified.
            !
            nbcs = registered_bcs%size()
            do ibc = 1,nbcs
                call registered_bcs%data(ibc)%state%init()
            end do



            ! Confirm initialization
            initialized = .true.

        end if


    end subroutine register_bcs
    !********************************************************************************************








    !>  Boundary condition factory
    !!      - Allocate a concrete boundary condition type based on the incoming string specification.
    !!      - Initialize the allocated boundary condition.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/31/2016
    !!
    !!  @param[in]      string  Character string used to select the appropriate boundary condition
    !!  @param[inout]   bc      Allocatable boundary condition
    !!
    !----------------------------------------------------------------------------------------------------
    subroutine create_bc(bcstring,bc)
        character(*),                       intent(in)      :: bcstring
        class(bc_state_t),  allocatable,    intent(inout)   :: bc

        integer(ik) :: ierr, bcindex


        if ( allocated(bc) ) then
            deallocate(bc)
        end if



        ! Find boundary condition string in 'registered_bcs' vector
        bcindex = registered_bcs%index_by_name(trim(bcstring))
        if (bcindex == 0) call chidg_signal_one(FATAL,"create_bc: boundary condition not recognized", trim(bcstring))


        ! Allocate conrete bc_t instance
        allocate(bc, source=registered_bcs%data(bcindex)%state, stat=ierr)
        if (ierr /= 0) call chidg_signal(FATAL,"create_bc: error allocating boundary condition from global vector.")


        ! Check boundary condition was allocated
        if ( .not. allocated(bc) ) call chidg_signal(FATAL,"create_bc: error allocating concrete boundary condition.")



    end subroutine create_bc
    !******************************************************************************************************







    !>  This is really just a utilitity for 'chidg edit' to dynamically list the avalable 
    !!  boundary conditions.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2016
    !!
    !-----------------------------------------------------------------------------------------------------
    subroutine list_bcs()
        integer                     :: nbcs, ibc
        character(:),   allocatable :: bcname

        nbcs = registered_bcs%size()


        do ibc = 1,nbcs

            bcname = registered_bcs%data(ibc)%state%get_name()
            call write_line(trim(bcname))

        end do ! ieqn

    end subroutine list_bcs
    !*****************************************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/1/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------------------
    function check_bc_state_registered(state_string) result(state_found)
        character(len=*),   intent(in)  :: state_string

        integer(ik) :: state_index
        logical     :: state_found

        ! Find boundary condition string in 'registered_bcs' vector
        state_index = registered_bcs%index_by_name(trim(state_string))

        ! Set status of state_found
        state_found = (state_index /= 0)

    end function check_bc_state_registered
    !*******************************************************************************************************

































end module mod_bc
