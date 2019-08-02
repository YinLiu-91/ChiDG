module mod_plot3d_utilities
#include <messenger.h>
    use mod_kinds,      only: ik, rk
    use mod_constants,  only: XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX
    use type_point,     only: point_t
    implicit none





contains

    !----------------------------------------------------------------------------------------
    !!
    !!  API for extracting information from Plot3D block-structured grids
    !!
    !!  Procedures:
    !!  -----------
    !!  get_block_points_plot3d                   - Return nodes
    !!  get_block_elements_plot3d                 - Return element connectivities
    !!  get_block_boundary_faces_plot3d           - Return face connectivities for boundary
    !!  check_block_mapping_conformation_plot3d   - Check mesh conforms to agglomeration
    !!      
    !!
    !****************************************************************************************




    !>  Return a linear(1D) array of points for the grid.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   10/16/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    function get_block_points_plot3d(xcoords,ycoords,zcoords) result(points)
        real(rk),   intent(in)  :: xcoords(:,:,:)
        real(rk),   intent(in)  :: ycoords(:,:,:)
        real(rk),   intent(in)  :: zcoords(:,:,:)

        !type(point_t),  allocatable :: points(:)
        real(rk),       allocatable :: points(:,:)
        integer(ik)                 :: ipt, npts, i,j,k, ierr



        npts = size(xcoords,1)*size(xcoords,2)*size(xcoords,3)

        
        allocate(points(npts,3), stat=ierr)
        if (ierr /= 0) call AllocationError


        ipt = 1
        do k = 1,size(xcoords,3)
            do j = 1,size(xcoords,2)
                do i = 1,size(xcoords,1)

                    points(ipt,1) = xcoords(i,j,k)    
                    points(ipt,2) = ycoords(i,j,k)    
                    points(ipt,3) = zcoords(i,j,k)    
    
                    ipt = ipt + 1

                end do ! i
            end do ! j
        end do ! k


    end function get_block_points_plot3d
    !****************************************************************************************






    !>  Given coordinate arrays for a block-structured grid, return an array of element
    !!  indices for the block.
    !!
    !!  Element connectivities correspond to CGNS convention.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   10/15/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    function get_block_elements_plot3d(xcoords,ycoords,zcoords,order,idomain) result(elements_cgns)
        real(rk),       intent(in)  :: xcoords(:,:,:)
        real(rk),       intent(in)  :: ycoords(:,:,:)
        real(rk),       intent(in)  :: zcoords(:,:,:)
        integer(ik),    intent(in)  :: order
        integer(ik),    intent(in)  :: idomain

        integer(ik) :: npt_i, npt_j, npt_k, nelem_i, nelem_j, nelem_k, nelem,               &
                       info_size, npts_1d, npts_element, ielem, ielem_i, ielem_j, ielem_k,  &
                       istart_i, istart_j, istart_k, ipt_i, ipt_j, ipt_k, ipt, ipt_elem,    &
                       ierr, inode, inode_inner

        integer(ik), allocatable    :: elements_plot3d(:,:), elements_cgns(:,:)

        logical :: exists, unique

        !
        ! Dimensions for reading plot3d grid
        !
        npt_i = size(xcoords,1)
        npt_j = size(xcoords,2)
        npt_k = size(xcoords,3)


        !
        ! Determine number of points for geometry features
        !
        npts_1d      = order+1
        npts_element = npts_1d * npts_1d * npts_1d


        !
        ! Compute number of elements in current block
        !
        nelem_i = (npt_i-1)/order
        nelem_j = (npt_j-1)/order
        nelem_k = (npt_k-1)/order
        nelem   = nelem_i * nelem_j * nelem_k



        !
        ! Generate element connectivities
        !
        info_size = 3  ! idomain, ielem, elem_type, ipt_1, ipt_2, ipt_3, ...


        allocate(elements_plot3d(nelem, info_size+npts_element), stat=ierr)
        if (ierr /= 0) call AllocationError

        ielem = 1
        do ielem_k = 1,nelem_k
            do ielem_j = 1,nelem_j
                do ielem_i = 1,nelem_i

                    ! Set element info
                    elements_plot3d(ielem,1) = idomain
                    elements_plot3d(ielem,2) = ielem
                    elements_plot3d(ielem,3) = order

                    ! Get starting point
                    istart_i = 1 + ((ielem_i-1)*order) 
                    istart_j = 1 + ((ielem_j-1)*order) 
                    istart_k = 1 + ((ielem_k-1)*order) 

                    !
                    ! For the current element, compute node indices
                    !
                    ipt=1       ! Global point index
                    ipt_elem=1  ! Local-element point index
                    do ipt_k = istart_k,(istart_k + order)
                        do ipt_j = istart_j,(istart_j + order)
                            do ipt_i = istart_i,(istart_i + order)

                                ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                elements_plot3d(ielem,info_size+ipt_elem) = ipt

                                ipt_elem = ipt_elem + 1
                            end do
                        end do
                    end do


                    ielem = ielem + 1
                end do
            end do
        end do



        !
        ! Convert to CGNS connectivity
        !
        elements_cgns = elements_plot3d

        do ielem = 1,size(elements_plot3d,1)

            select case (order)

                ! Linear hexahedrals: HEXA_8
                case(1)
                    elements_cgns(ielem,info_size+1) = elements_plot3d(ielem,info_size+1)
                    elements_cgns(ielem,info_size+2) = elements_plot3d(ielem,info_size+2)
                    elements_cgns(ielem,info_size+3) = elements_plot3d(ielem,info_size+4)
                    elements_cgns(ielem,info_size+4) = elements_plot3d(ielem,info_size+3)

                    elements_cgns(ielem,info_size+5) = elements_plot3d(ielem,info_size+5)
                    elements_cgns(ielem,info_size+6) = elements_plot3d(ielem,info_size+6)
                    elements_cgns(ielem,info_size+7) = elements_plot3d(ielem,info_size+8)
                    elements_cgns(ielem,info_size+8) = elements_plot3d(ielem,info_size+7)





                ! Quadratic hexahedrals: HEXA_27
                case(2)
                    elements_cgns(ielem,info_size+1) = elements_plot3d(ielem,info_size+1)
                    elements_cgns(ielem,info_size+2) = elements_plot3d(ielem,info_size+3)
                    elements_cgns(ielem,info_size+3) = elements_plot3d(ielem,info_size+9)
                    elements_cgns(ielem,info_size+4) = elements_plot3d(ielem,info_size+7)

                    elements_cgns(ielem,info_size+5) = elements_plot3d(ielem,info_size+19)
                    elements_cgns(ielem,info_size+6) = elements_plot3d(ielem,info_size+21)
                    elements_cgns(ielem,info_size+7) = elements_plot3d(ielem,info_size+27)
                    elements_cgns(ielem,info_size+8) = elements_plot3d(ielem,info_size+25)

                    elements_cgns(ielem,info_size+9 ) = elements_plot3d(ielem,info_size+2)
                    elements_cgns(ielem,info_size+10) = elements_plot3d(ielem,info_size+6)
                    elements_cgns(ielem,info_size+11) = elements_plot3d(ielem,info_size+8)
                    elements_cgns(ielem,info_size+12) = elements_plot3d(ielem,info_size+4)

                    elements_cgns(ielem,info_size+13) = elements_plot3d(ielem,info_size+10)
                    elements_cgns(ielem,info_size+14) = elements_plot3d(ielem,info_size+12)
                    elements_cgns(ielem,info_size+15) = elements_plot3d(ielem,info_size+18)
                    elements_cgns(ielem,info_size+16) = elements_plot3d(ielem,info_size+16)

                    elements_cgns(ielem,info_size+17) = elements_plot3d(ielem,info_size+20)
                    elements_cgns(ielem,info_size+18) = elements_plot3d(ielem,info_size+24)
                    elements_cgns(ielem,info_size+19) = elements_plot3d(ielem,info_size+26)
                    elements_cgns(ielem,info_size+20) = elements_plot3d(ielem,info_size+22)

                    elements_cgns(ielem,info_size+21) = elements_plot3d(ielem,info_size+5)
                    elements_cgns(ielem,info_size+22) = elements_plot3d(ielem,info_size+11)
                    elements_cgns(ielem,info_size+23) = elements_plot3d(ielem,info_size+15)
                    elements_cgns(ielem,info_size+24) = elements_plot3d(ielem,info_size+17)

                    elements_cgns(ielem,info_size+25) = elements_plot3d(ielem,info_size+13)
                    elements_cgns(ielem,info_size+26) = elements_plot3d(ielem,info_size+23)
                    elements_cgns(ielem,info_size+27) = elements_plot3d(ielem,info_size+14)

                ! Cubic hexahedrals: HEXA_64
                case(3)
                
                    elements_cgns(ielem,info_size+1 ) = elements_plot3d(ielem,info_size+1)
                    elements_cgns(ielem,info_size+2 ) = elements_plot3d(ielem,info_size+4)
                    elements_cgns(ielem,info_size+3 ) = elements_plot3d(ielem,info_size+16)
                    elements_cgns(ielem,info_size+4 ) = elements_plot3d(ielem,info_size+13)

                    elements_cgns(ielem,info_size+5 ) = elements_plot3d(ielem,info_size+49)
                    elements_cgns(ielem,info_size+6 ) = elements_plot3d(ielem,info_size+52)
                    elements_cgns(ielem,info_size+7 ) = elements_plot3d(ielem,info_size+64)
                    elements_cgns(ielem,info_size+8 ) = elements_plot3d(ielem,info_size+61)

                    elements_cgns(ielem,info_size+9 ) = elements_plot3d(ielem,info_size+2)
                    elements_cgns(ielem,info_size+10) = elements_plot3d(ielem,info_size+3)
                    elements_cgns(ielem,info_size+11) = elements_plot3d(ielem,info_size+8)
                    elements_cgns(ielem,info_size+12) = elements_plot3d(ielem,info_size+12)

                    elements_cgns(ielem,info_size+13) = elements_plot3d(ielem,info_size+15)
                    elements_cgns(ielem,info_size+14) = elements_plot3d(ielem,info_size+14)
                    elements_cgns(ielem,info_size+15) = elements_plot3d(ielem,info_size+9)
                    elements_cgns(ielem,info_size+16) = elements_plot3d(ielem,info_size+5)

                    elements_cgns(ielem,info_size+17) = elements_plot3d(ielem,info_size+17)
                    elements_cgns(ielem,info_size+18) = elements_plot3d(ielem,info_size+33)
                    elements_cgns(ielem,info_size+19) = elements_plot3d(ielem,info_size+20)
                    elements_cgns(ielem,info_size+20) = elements_plot3d(ielem,info_size+36)

                    elements_cgns(ielem,info_size+21) = elements_plot3d(ielem,info_size+32)
                    elements_cgns(ielem,info_size+22) = elements_plot3d(ielem,info_size+48)
                    elements_cgns(ielem,info_size+23) = elements_plot3d(ielem,info_size+29)
                    elements_cgns(ielem,info_size+24) = elements_plot3d(ielem,info_size+45)

                    elements_cgns(ielem,info_size+25) = elements_plot3d(ielem,info_size+50)
                    elements_cgns(ielem,info_size+26) = elements_plot3d(ielem,info_size+51)
                    elements_cgns(ielem,info_size+27) = elements_plot3d(ielem,info_size+56)
                    elements_cgns(ielem,info_size+28) = elements_plot3d(ielem,info_size+60)

                    elements_cgns(ielem,info_size+29) = elements_plot3d(ielem,info_size+63)
                    elements_cgns(ielem,info_size+30) = elements_plot3d(ielem,info_size+62)
                    elements_cgns(ielem,info_size+31) = elements_plot3d(ielem,info_size+57)
                    elements_cgns(ielem,info_size+32) = elements_plot3d(ielem,info_size+53)

                    elements_cgns(ielem,info_size+33) = elements_plot3d(ielem,info_size+6)
                    elements_cgns(ielem,info_size+34) = elements_plot3d(ielem,info_size+7)
                    elements_cgns(ielem,info_size+35) = elements_plot3d(ielem,info_size+11)
                    elements_cgns(ielem,info_size+36) = elements_plot3d(ielem,info_size+10)

                    elements_cgns(ielem,info_size+37) = elements_plot3d(ielem,info_size+18)
                    elements_cgns(ielem,info_size+38) = elements_plot3d(ielem,info_size+19)
                    elements_cgns(ielem,info_size+39) = elements_plot3d(ielem,info_size+35)
                    elements_cgns(ielem,info_size+40) = elements_plot3d(ielem,info_size+34)

                    elements_cgns(ielem,info_size+41) = elements_plot3d(ielem,info_size+24)
                    elements_cgns(ielem,info_size+42) = elements_plot3d(ielem,info_size+28)
                    elements_cgns(ielem,info_size+43) = elements_plot3d(ielem,info_size+44)
                    elements_cgns(ielem,info_size+44) = elements_plot3d(ielem,info_size+40)

                    elements_cgns(ielem,info_size+45) = elements_plot3d(ielem,info_size+31)
                    elements_cgns(ielem,info_size+46) = elements_plot3d(ielem,info_size+30)
                    elements_cgns(ielem,info_size+47) = elements_plot3d(ielem,info_size+46)
                    elements_cgns(ielem,info_size+48) = elements_plot3d(ielem,info_size+47)

                    elements_cgns(ielem,info_size+49) = elements_plot3d(ielem,info_size+25)
                    elements_cgns(ielem,info_size+50) = elements_plot3d(ielem,info_size+21)
                    elements_cgns(ielem,info_size+51) = elements_plot3d(ielem,info_size+37)
                    elements_cgns(ielem,info_size+52) = elements_plot3d(ielem,info_size+41)

                    elements_cgns(ielem,info_size+53) = elements_plot3d(ielem,info_size+54)
                    elements_cgns(ielem,info_size+54) = elements_plot3d(ielem,info_size+55)
                    elements_cgns(ielem,info_size+55) = elements_plot3d(ielem,info_size+59)
                    elements_cgns(ielem,info_size+56) = elements_plot3d(ielem,info_size+58)

                    elements_cgns(ielem,info_size+57) = elements_plot3d(ielem,info_size+22)
                    elements_cgns(ielem,info_size+58) = elements_plot3d(ielem,info_size+23)
                    elements_cgns(ielem,info_size+59) = elements_plot3d(ielem,info_size+27)
                    elements_cgns(ielem,info_size+60) = elements_plot3d(ielem,info_size+26)

                    elements_cgns(ielem,info_size+61) = elements_plot3d(ielem,info_size+38)
                    elements_cgns(ielem,info_size+62) = elements_plot3d(ielem,info_size+39)
                    elements_cgns(ielem,info_size+63) = elements_plot3d(ielem,info_size+43)
                    elements_cgns(ielem,info_size+64) = elements_plot3d(ielem,info_size+42)

                ! Quartic hexahedrals: HEXA_125
                case(4)

                    elements_cgns(ielem,info_size+1 )  = elements_plot3d(ielem,info_size+1)
                    elements_cgns(ielem,info_size+2 )  = elements_plot3d(ielem,info_size+5)
                    elements_cgns(ielem,info_size+3 )  = elements_plot3d(ielem,info_size+25)
                    elements_cgns(ielem,info_size+4 )  = elements_plot3d(ielem,info_size+21)
                    elements_cgns(ielem,info_size+5 )  = elements_plot3d(ielem,info_size+101)
                    elements_cgns(ielem,info_size+6 )  = elements_plot3d(ielem,info_size+105)
                    elements_cgns(ielem,info_size+7 )  = elements_plot3d(ielem,info_size+125)
                    elements_cgns(ielem,info_size+8 )  = elements_plot3d(ielem,info_size+121)
                    elements_cgns(ielem,info_size+9 )  = elements_plot3d(ielem,info_size+2)

                    elements_cgns(ielem,info_size+10)  = elements_plot3d(ielem,info_size+3)
                    elements_cgns(ielem,info_size+11)  = elements_plot3d(ielem,info_size+4)
                    elements_cgns(ielem,info_size+12)  = elements_plot3d(ielem,info_size+10)
                    elements_cgns(ielem,info_size+13)  = elements_plot3d(ielem,info_size+15)
                    elements_cgns(ielem,info_size+14)  = elements_plot3d(ielem,info_size+20)
                    elements_cgns(ielem,info_size+15)  = elements_plot3d(ielem,info_size+24)
                    elements_cgns(ielem,info_size+16)  = elements_plot3d(ielem,info_size+23)
                    elements_cgns(ielem,info_size+17)  = elements_plot3d(ielem,info_size+22)
                    elements_cgns(ielem,info_size+18)  = elements_plot3d(ielem,info_size+16)
                    elements_cgns(ielem,info_size+19)  = elements_plot3d(ielem,info_size+11)

                    elements_cgns(ielem,info_size+20)  = elements_plot3d(ielem,info_size+6)
                    elements_cgns(ielem,info_size+21)  = elements_plot3d(ielem,info_size+26)
                    elements_cgns(ielem,info_size+22)  = elements_plot3d(ielem,info_size+51)
                    elements_cgns(ielem,info_size+23)  = elements_plot3d(ielem,info_size+76)
                    elements_cgns(ielem,info_size+24)  = elements_plot3d(ielem,info_size+30)
                    elements_cgns(ielem,info_size+25)  = elements_plot3d(ielem,info_size+55)
                    elements_cgns(ielem,info_size+26)  = elements_plot3d(ielem,info_size+80)
                    elements_cgns(ielem,info_size+27)  = elements_plot3d(ielem,info_size+50)
                    elements_cgns(ielem,info_size+28)  = elements_plot3d(ielem,info_size+75)
                    elements_cgns(ielem,info_size+29)  = elements_plot3d(ielem,info_size+100)

                    elements_cgns(ielem,info_size+30)  = elements_plot3d(ielem,info_size+46)
                    elements_cgns(ielem,info_size+31)  = elements_plot3d(ielem,info_size+71)
                    elements_cgns(ielem,info_size+32)  = elements_plot3d(ielem,info_size+96)
                    elements_cgns(ielem,info_size+33)  = elements_plot3d(ielem,info_size+102)
                    elements_cgns(ielem,info_size+34)  = elements_plot3d(ielem,info_size+103)
                    elements_cgns(ielem,info_size+35)  = elements_plot3d(ielem,info_size+104)
                    elements_cgns(ielem,info_size+36)  = elements_plot3d(ielem,info_size+110)
                    elements_cgns(ielem,info_size+37)  = elements_plot3d(ielem,info_size+115)
                    elements_cgns(ielem,info_size+38)  = elements_plot3d(ielem,info_size+120)
                    elements_cgns(ielem,info_size+39)  = elements_plot3d(ielem,info_size+124)

                    elements_cgns(ielem,info_size+40)  = elements_plot3d(ielem,info_size+123)
                    elements_cgns(ielem,info_size+41)  = elements_plot3d(ielem,info_size+122)
                    elements_cgns(ielem,info_size+42)  = elements_plot3d(ielem,info_size+116)
                    elements_cgns(ielem,info_size+43)  = elements_plot3d(ielem,info_size+111)
                    elements_cgns(ielem,info_size+44)  = elements_plot3d(ielem,info_size+106)
                    elements_cgns(ielem,info_size+45)  = elements_plot3d(ielem,info_size+7)
                    elements_cgns(ielem,info_size+46)  = elements_plot3d(ielem,info_size+8)
                    elements_cgns(ielem,info_size+47)  = elements_plot3d(ielem,info_size+9)
                    elements_cgns(ielem,info_size+48)  = elements_plot3d(ielem,info_size+14)
                    elements_cgns(ielem,info_size+49)  = elements_plot3d(ielem,info_size+19)

                    elements_cgns(ielem,info_size+50)  = elements_plot3d(ielem,info_size+18)
                    elements_cgns(ielem,info_size+51)  = elements_plot3d(ielem,info_size+17)
                    elements_cgns(ielem,info_size+52)  = elements_plot3d(ielem,info_size+12)
                    elements_cgns(ielem,info_size+53)  = elements_plot3d(ielem,info_size+13)
                    elements_cgns(ielem,info_size+54)  = elements_plot3d(ielem,info_size+27)
                    elements_cgns(ielem,info_size+55)  = elements_plot3d(ielem,info_size+28)
                    elements_cgns(ielem,info_size+56)  = elements_plot3d(ielem,info_size+29)
                    elements_cgns(ielem,info_size+57)  = elements_plot3d(ielem,info_size+54)
                    elements_cgns(ielem,info_size+58)  = elements_plot3d(ielem,info_size+79)
                    elements_cgns(ielem,info_size+59)  = elements_plot3d(ielem,info_size+78)

                    elements_cgns(ielem,info_size+60)  = elements_plot3d(ielem,info_size+77)
                    elements_cgns(ielem,info_size+61)  = elements_plot3d(ielem,info_size+52)
                    elements_cgns(ielem,info_size+62)  = elements_plot3d(ielem,info_size+53)
                    elements_cgns(ielem,info_size+63)  = elements_plot3d(ielem,info_size+35)
                    elements_cgns(ielem,info_size+64)  = elements_plot3d(ielem,info_size+40)
                    elements_cgns(ielem,info_size+65)  = elements_plot3d(ielem,info_size+45)
                    elements_cgns(ielem,info_size+66)  = elements_plot3d(ielem,info_size+70)
                    elements_cgns(ielem,info_size+67)  = elements_plot3d(ielem,info_size+95)
                    elements_cgns(ielem,info_size+68)  = elements_plot3d(ielem,info_size+90)
                    elements_cgns(ielem,info_size+69)  = elements_plot3d(ielem,info_size+85)

                    elements_cgns(ielem,info_size+70)  = elements_plot3d(ielem,info_size+60)
                    elements_cgns(ielem,info_size+71)  = elements_plot3d(ielem,info_size+65)
                    elements_cgns(ielem,info_size+72)  = elements_plot3d(ielem,info_size+49)
                    elements_cgns(ielem,info_size+73)  = elements_plot3d(ielem,info_size+48)
                    elements_cgns(ielem,info_size+74)  = elements_plot3d(ielem,info_size+47)
                    elements_cgns(ielem,info_size+75)  = elements_plot3d(ielem,info_size+72)
                    elements_cgns(ielem,info_size+76)  = elements_plot3d(ielem,info_size+97)
                    elements_cgns(ielem,info_size+77)  = elements_plot3d(ielem,info_size+98)
                    elements_cgns(ielem,info_size+78)  = elements_plot3d(ielem,info_size+99)
                    elements_cgns(ielem,info_size+79)  = elements_plot3d(ielem,info_size+74)

                    elements_cgns(ielem,info_size+80)  = elements_plot3d(ielem,info_size+73)
                    elements_cgns(ielem,info_size+81)  = elements_plot3d(ielem,info_size+41)
                    elements_cgns(ielem,info_size+82)  = elements_plot3d(ielem,info_size+36)
                    elements_cgns(ielem,info_size+83)  = elements_plot3d(ielem,info_size+31)
                    elements_cgns(ielem,info_size+84)  = elements_plot3d(ielem,info_size+56)
                    elements_cgns(ielem,info_size+85)  = elements_plot3d(ielem,info_size+81)
                    elements_cgns(ielem,info_size+86)  = elements_plot3d(ielem,info_size+86)
                    elements_cgns(ielem,info_size+87)  = elements_plot3d(ielem,info_size+91)
                    elements_cgns(ielem,info_size+88)  = elements_plot3d(ielem,info_size+66)
                    elements_cgns(ielem,info_size+89)  = elements_plot3d(ielem,info_size+61)

                    elements_cgns(ielem,info_size+90)  = elements_plot3d(ielem,info_size+107)
                    elements_cgns(ielem,info_size+91)  = elements_plot3d(ielem,info_size+108)
                    elements_cgns(ielem,info_size+92)  = elements_plot3d(ielem,info_size+109)
                    elements_cgns(ielem,info_size+93)  = elements_plot3d(ielem,info_size+114)
                    elements_cgns(ielem,info_size+94)  = elements_plot3d(ielem,info_size+119)
                    elements_cgns(ielem,info_size+95)  = elements_plot3d(ielem,info_size+118)
                    elements_cgns(ielem,info_size+96)  = elements_plot3d(ielem,info_size+117)
                    elements_cgns(ielem,info_size+97)  = elements_plot3d(ielem,info_size+112)
                    elements_cgns(ielem,info_size+98)  = elements_plot3d(ielem,info_size+113)
                    elements_cgns(ielem,info_size+99)  = elements_plot3d(ielem,info_size+32)

                    elements_cgns(ielem,info_size+100) = elements_plot3d(ielem,info_size+33)
                    elements_cgns(ielem,info_size+101) = elements_plot3d(ielem,info_size+34)
                    elements_cgns(ielem,info_size+102) = elements_plot3d(ielem,info_size+39)
                    elements_cgns(ielem,info_size+103) = elements_plot3d(ielem,info_size+44)
                    elements_cgns(ielem,info_size+104) = elements_plot3d(ielem,info_size+43)
                    elements_cgns(ielem,info_size+105) = elements_plot3d(ielem,info_size+42)
                    elements_cgns(ielem,info_size+106) = elements_plot3d(ielem,info_size+37)
                    elements_cgns(ielem,info_size+107) = elements_plot3d(ielem,info_size+38)
                    elements_cgns(ielem,info_size+108) = elements_plot3d(ielem,info_size+57)
                    elements_cgns(ielem,info_size+109) = elements_plot3d(ielem,info_size+58)

                    elements_cgns(ielem,info_size+110) = elements_plot3d(ielem,info_size+59)
                    elements_cgns(ielem,info_size+111) = elements_plot3d(ielem,info_size+64)
                    elements_cgns(ielem,info_size+112) = elements_plot3d(ielem,info_size+69)
                    elements_cgns(ielem,info_size+113) = elements_plot3d(ielem,info_size+68)
                    elements_cgns(ielem,info_size+114) = elements_plot3d(ielem,info_size+67)
                    elements_cgns(ielem,info_size+115) = elements_plot3d(ielem,info_size+62)
                    elements_cgns(ielem,info_size+116) = elements_plot3d(ielem,info_size+63)
                    elements_cgns(ielem,info_size+117) = elements_plot3d(ielem,info_size+82)
                    elements_cgns(ielem,info_size+118) = elements_plot3d(ielem,info_size+83)
                    elements_cgns(ielem,info_size+119) = elements_plot3d(ielem,info_size+84)

                    elements_cgns(ielem,info_size+120) = elements_plot3d(ielem,info_size+89)
                    elements_cgns(ielem,info_size+121) = elements_plot3d(ielem,info_size+94)
                    elements_cgns(ielem,info_size+122) = elements_plot3d(ielem,info_size+93)
                    elements_cgns(ielem,info_size+123) = elements_plot3d(ielem,info_size+92)
                    elements_cgns(ielem,info_size+124) = elements_plot3d(ielem,info_size+87)
                    elements_cgns(ielem,info_size+125) = elements_plot3d(ielem,info_size+88)



            end select



            !
            ! Check node indices are each a part of the original node set to catch errors
            !
            do inode = 1,(size(elements_cgns,2) - info_size)

                ! Check exists in original node set
                exists = .false.
                do inode_inner = 1,(size(elements_plot3d,2) - info_size)
                    if ( elements_cgns(ielem,info_size+inode) == elements_plot3d(ielem,info_size+inode_inner) ) then
                        exists = .true.
                        exit
                    end if
                end do !inode_tmp

                if (.not. exists) call chidg_signal(FATAL,'get_block_elements_plot3d: node mapped to CGNS connectivity does not exist in Plot3D connectivity.')
            end do !inode



            !
            ! Check node indices are unique for each element to catch duplication error.
            !
            do inode = 1,(size(elements_cgns,2) - info_size)

                ! Check no duplicate nodes in cgns set.
                unique = .true.
                do inode_inner = 1,(size(elements_cgns,2) - info_size)
                    if ( (inode /= inode_inner) .and. &
                         (elements_cgns(ielem,info_size+inode) == elements_cgns(ielem,info_size+inode_inner)) ) then
                        unique = .false.
                        exit
                    end if
                end do !inode_tmp

                if (.not. unique) call chidg_signal(FATAL,'get_block_elements_plot3d: nodes mapped to CGNS connectivity from Plot3D are not unique.')
            end do !inode





        end do !ielem





    end function get_block_elements_plot3d
    !****************************************************************************************





    !>  Given coordinate arrays for a block-structured grid and a face, return
    !!  an array of face node indices for the specified boundary.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   10/15/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    function get_block_boundary_faces_plot3d(xcoords,ycoords,zcoords,mapping,bcface) result(faces)
        real(rk),       intent(in)  :: xcoords(:,:,:)
        real(rk),       intent(in)  :: ycoords(:,:,:)
        real(rk),       intent(in)  :: zcoords(:,:,:)
        integer(ik),    intent(in)  :: mapping
        integer(ik),    intent(in)  :: bcface

        integer(ik), allocatable    :: faces(:,:)

        integer(ik) :: ipt_i, ipt_j, ipt_k, ipt, ipt_face, npt_i, npt_j, npt_k, npts, &
                       iface_i, iface_j, iface_k, iface, nelem_i, nelem_j, nelem_k, nelem, &
                       nfaces_xi, nfaces_eta, nfaces_zeta, npts_1d, npts_face, npts_element, &
                       pointstart_i, pointstart_j, pointstart_k 


        !
        ! Check block conforms to agglomeration routine for higher-order elements
        !
        call check_block_mapping_conformation_plot3d(xcoords,ycoords,zcoords,mapping)


        !
        ! Point dimensions for block
        !
        npt_i = size(xcoords,1)
        npt_j = size(xcoords,2)
        npt_k = size(xcoords,3)
        npts  = npt_i * npt_j * npt_k


        !
        ! Compute number of points for geometry features
        !
        npts_1d      = mapping+1
        npts_face    = npts_1d * npts_1d
        npts_element = npts_1d * npts_1d * npts_1d


        !
        ! Compute number of elements in each direction and total nelem
        !
        nelem_i = (npt_i-1)/mapping
        nelem_j = (npt_j-1)/mapping
        nelem_k = (npt_k-1)/mapping
        nelem   = nelem_i * nelem_j * nelem_k


        !
        ! Get number of faces in each direction
        !
        nfaces_xi   = nelem_j * nelem_k
        nfaces_eta  = nelem_i * nelem_k
        nfaces_zeta = nelem_i * nelem_j



        select case (bcface)
            case (XI_MIN)
                allocate(faces(nfaces_xi,npts_face))
                ipt_i   = 1
                iface = 1
                do iface_k = 1,nelem_k
                    do iface_j = 1,nelem_j
                            pointstart_j = 1 + (iface_j-1)*mapping
                            pointstart_k = 1 + (iface_k-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_k = pointstart_k,(pointstart_k + mapping)
                                do ipt_j = pointstart_j,(pointstart_j + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do



            case (XI_MAX)
                allocate(faces(nfaces_xi,npts_face))
                ipt_i   = npt_i
                iface = 1
                do iface_k = 1,nelem_k
                    do iface_j = 1,nelem_j
                            pointstart_j = 1 + (iface_j-1)*mapping
                            pointstart_k = 1 + (iface_k-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_k = pointstart_k,(pointstart_k + mapping)
                                do ipt_j = pointstart_j,(pointstart_j + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do



            case (ETA_MIN)
                allocate(faces(nfaces_eta,npts_face))
                ipt_j   = 1
                iface = 1
                do iface_k = 1,nelem_k
                    do iface_i = 1,nelem_i
                            pointstart_i = 1 + (iface_i-1)*mapping
                            pointstart_k = 1 + (iface_k-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_k = pointstart_k,(pointstart_k + mapping)
                                do ipt_i = pointstart_i,(pointstart_i + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do



            case (ETA_MAX)
                allocate(faces(nfaces_eta,npts_face))
                ipt_j   = npt_j
                iface = 1
                do iface_k = 1,nelem_k
                    do iface_i = 1,nelem_i
                            pointstart_i = 1 + (iface_i-1)*mapping
                            pointstart_k = 1 + (iface_k-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_k = pointstart_k,(pointstart_k + mapping)
                                do ipt_i = pointstart_i,(pointstart_i + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do



            case (ZETA_MIN)
                allocate(faces(nfaces_zeta,npts_face))
                ipt_k   = 1
                iface = 1
                do iface_j = 1,nelem_j
                    do iface_i = 1,nelem_i
                            pointstart_i = 1 + (iface_i-1)*mapping
                            pointstart_j = 1 + (iface_j-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_j = pointstart_j,(pointstart_j + mapping)
                                do ipt_i = pointstart_i,(pointstart_i + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do



            case (ZETA_MAX)
                allocate(faces(nfaces_zeta,npts_face))
                ipt_k   = npt_k
                iface = 1
                do iface_j = 1,nelem_j
                    do iface_i = 1,nelem_i
                            pointstart_i = 1 + (iface_i-1)*mapping
                            pointstart_j = 1 + (iface_j-1)*mapping
                            ipt=1       ! Global point index
                            ipt_face=1  ! Local-element point index
                            do ipt_j = pointstart_j,(pointstart_j + mapping)
                                do ipt_i = pointstart_i,(pointstart_i + mapping)
                                    ipt = ipt_i  +  (ipt_j-1)*npt_i  +  (ipt_k-1)*(npt_i*npt_j)
                                    faces(iface,ipt_face) = ipt
                                    ipt_face = ipt_face + 1
                                end do
                            end do
                            iface = iface + 1
                    end do
                end do


            case default
                call chidg_signal(FATAL, "get_block_boundary_faces_plot3d: Invalid block face to get faces from")

        end select




    end function get_block_boundary_faces_plot3d
    !****************************************************************************************









    !>  Given coordinate arrays for a block-structured grid, check that the point
    !!  counts in each direction conform to the rule for agglomerating elements
    !!  in order to create higher-order elements.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   10/15/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine check_block_mapping_conformation_plot3d(xcoords,ycoords,zcoords,mapping)
        real(rk),       intent(in)  :: xcoords(:,:,:)
        real(rk),       intent(in)  :: ycoords(:,:,:)
        real(rk),       intent(in)  :: zcoords(:,:,:)
        integer(ik),    intent(in)  :: mapping

        integer(ik) :: ipt, npt_i, npt_j, npt_k, npts_1d, nelem_i, nelem_j, nelem_k


        ! Point dimensions for block
        npt_i   = size(xcoords,1)
        npt_j   = size(xcoords,2)
        npt_k   = size(xcoords,3)
        npts_1d = mapping+1


        !
        ! Test that block conforms to element mapping via agglomeration
        !
        !
        ! Count number of elements in each direction and check block conforms to
        ! the agglomeration rule for higher-order elements
        !
        nelem_i = 0
        ipt = 1
        do while (ipt < npt_i)
            nelem_i = nelem_i + 1
            ipt = ipt + (npts_1d-1)
        end do
        if (ipt > npt_i) call chidg_signal(FATAL,"Block mesh does not conform to agglomeration routine in 'i'")

        nelem_j = 0
        ipt = 1
        do while (ipt < npt_j)
            nelem_j = nelem_j + 1
            ipt = ipt + (npts_1d-1)
        end do
        if (ipt > npt_j) call chidg_signal(FATAL,"Block mesh does not conform to agglomeration routine in 'j'")

        nelem_k = 0
        ipt = 1
        do while (ipt < npt_k)
            nelem_k = nelem_k + 1
            ipt = ipt + (npts_1d-1)
        end do
        if (ipt > npt_k) call chidg_signal(FATAL,"Block mesh does not conform to agglomeration routine in 'k'")



    end subroutine check_block_mapping_conformation_plot3d
    !****************************************************************************************






end module mod_plot3d_utilities
