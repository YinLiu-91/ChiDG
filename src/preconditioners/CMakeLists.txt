add_subdirectory(RASILU0)
add_subdirectory(RASILU0_overset)

add_lib_sources(
                type_preconditioner.f90 
                mod_preconditioner.f90
                precon_jacobi.f90
                precon_ILU0.f90
                precon_identity.f90
                precon_HB.f90
#                precon_line.f90
#                precon_schur_element.f90
#                precon_ILU0_MDF.f90
#                precon_ILU0_overset.f90
                precon_petsc.f90
                )

