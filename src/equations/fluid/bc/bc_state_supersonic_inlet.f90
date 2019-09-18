module bc_state_supersonic_inlet
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, TWO
    use mod_fluid,              only: gam

    use type_bc_state,          only: bc_state_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_point,             only: point_t
    use mpi_f08,                only: mpi_comm
    use DNAD_D
    implicit none


    !> Extrapolation boundary condition 
    !!      - Extrapolate interior variables to be used for calculating the boundary flux.
    !!  
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2016
    !!
    !-------------------------------------------------------------------------------------------
    type, public, extends(bc_state_t) :: supersonic_inlet_t

    contains

        procedure   :: init
        procedure   :: compute_bc_state

    end type supersonic_inlet_t
    !*******************************************************************************************




contains





    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(supersonic_inlet_t),   intent(inout) :: self
        
        !
        ! Set operator name
        !
        call self%set_name("Supersonic Inlet")
        call self%set_family("Inlet")


        !
        ! Add functions
        !
        call self%bcproperties%add('Density',   'Required')
        call self%bcproperties%add('Momentum-1','Required')
        call self%bcproperties%add('Momentum-2','Required')
        call self%bcproperties%add('Momentum-3','Required')
        call self%bcproperties%add('Energy',    'Required')



    end subroutine init
    !********************************************************************************










    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/8/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_COMM)
        class(supersonic_inlet_t),    intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        class(properties_t),        intent(inout)   :: prop
        type(mpi_comm),             intent(in)      :: bc_COMM



        ! Equation indices


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::              &
            density_m,  mom1_m,  mom2_m,  mom3_m,  energy_m,  p_m,    &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc, p_bc,   &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m,  &
            flux_x, flux_y, flux_z, integrand,                  &
            u_m,    v_m,    w_m,                                &
            u_bc,   v_bc,   w_bc

        !print *, 'compute supersonic inlet'

        grad1_density_m = worker%get_field("Density"   , 'grad1', 'face interior')
        grad2_density_m = worker%get_field("Density"   , 'grad2', 'face interior')
        grad3_density_m = worker%get_field("Density"   , 'grad3', 'face interior')

        grad1_mom1_m    = worker%get_field("Momentum-1", 'grad1', 'face interior')
        grad2_mom1_m    = worker%get_field("Momentum-1", 'grad2', 'face interior')
        grad3_mom1_m    = worker%get_field("Momentum-1", 'grad3', 'face interior')

        grad1_mom2_m    = worker%get_field("Momentum-2", 'grad1', 'face interior')
        grad2_mom2_m    = worker%get_field("Momentum-2", 'grad2', 'face interior')
        grad3_mom2_m    = worker%get_field("Momentum-2", 'grad3', 'face interior')

        grad1_mom3_m    = worker%get_field("Momentum-3", 'grad1', 'face interior')
        grad2_mom3_m    = worker%get_field("Momentum-3", 'grad2', 'face interior')
        grad3_mom3_m    = worker%get_field("Momentum-3", 'grad3', 'face interior')
        
        grad1_energy_m  = worker%get_field("Energy"    , 'grad1', 'face interior')
        grad2_energy_m  = worker%get_field("Energy"    , 'grad2', 'face interior')
        grad3_energy_m  = worker%get_field("Energy"    , 'grad3', 'face interior')


        !
        ! Initialize variables
        !
        density_m = worker%get_field("Density"   , 'value', 'face interior')
        density_bc = ZERO*density_m
        mom1_bc    = ZERO*density_m
        mom2_bc    = ZERO*density_m
        mom3_bc    = ZERO*density_m
        energy_bc  = ZERO*density_m


        !
        ! Get boundary condition Total Temperature, Total Pressure, and normal vector
        !
        density_bc = self%bcproperties%compute("Density",    worker%time(), worker%coords())
        mom1_bc    = self%bcproperties%compute("Momentum-1", worker%time(), worker%coords())
        mom2_bc    = self%bcproperties%compute("Momentum-2", worker%time(), worker%coords())
        mom3_bc    = self%bcproperties%compute("Momentum-3", worker%time(), worker%coords())
        energy_bc  = self%bcproperties%compute("Energy",     worker%time(), worker%coords())


        !
        ! Store computed boundary state
        !
        call worker%store_bc_state("Density"   , density_bc, 'value')
        call worker%store_bc_state("Momentum-1", mom1_bc,    'value')
        call worker%store_bc_state("Momentum-2", mom2_bc,    'value')
        call worker%store_bc_state("Momentum-3", mom3_bc,    'value')
        call worker%store_bc_state("Energy"    , energy_bc,  'value')




        call worker%store_bc_state("Density"   , grad1_density_m, 'grad1')
        call worker%store_bc_state("Density"   , grad2_density_m, 'grad2')
        call worker%store_bc_state("Density"   , grad3_density_m, 'grad3')

        call worker%store_bc_state("Momentum-1", grad1_mom1_m,    'grad1')
        call worker%store_bc_state("Momentum-1", grad2_mom1_m,    'grad2')
        call worker%store_bc_state("Momentum-1", grad3_mom1_m,    'grad3')
                                                
        call worker%store_bc_state("Momentum-2", grad1_mom2_m,    'grad1')
        call worker%store_bc_state("Momentum-2", grad2_mom2_m,    'grad2')
        call worker%store_bc_state("Momentum-2", grad3_mom2_m,    'grad3')
                                                
        call worker%store_bc_state("Momentum-3", grad1_mom3_m,    'grad1')
        call worker%store_bc_state("Momentum-3", grad2_mom3_m,    'grad2')
        call worker%store_bc_state("Momentum-3", grad3_mom3_m,    'grad3')
                                                
        call worker%store_bc_state("Energy"    , grad1_energy_m,  'grad1')
        call worker%store_bc_state("Energy"    , grad2_energy_m,  'grad2')
        call worker%store_bc_state("Energy"    , grad3_energy_m,  'grad3')

        !print *, 'compute supersonic inlet exit'









    end subroutine compute_bc_state
    !******************************************************************************************









end module bc_state_supersonic_inlet
