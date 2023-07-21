module get_arw_ensmod_mod

    use mpeu_util, only: die
    use mpimod, only: mype,npe
    use abstract_get_arw_ensmod_mod

    implicit none

    type, extends(abstract_get_arw_ensmod_class) :: get_arw_ensmod_class
    contains
        procedure, pass(this) :: non_gaussian_ens_grid_ => non_gaussian_ens_grid_arw
        procedure, pass(this) :: get_user_ens_ => get_user_ens_arw
    end type get_arw_ensmod_class

contains

subroutine get_user_ens_arw(this,grd,ntindex,atm_bundle,iret)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    get_user_ens_    pretend atmos bkg is the ensemble
!   prgmmr: mahajan          org: emc/ncep            date: 2016-06-30
!
! abstract: Read in WRFARW ensemble members in to GSI ensemble.
!
! program history log:
!   2016-06-30  mahajan  - initial code
!   2016-07-20  mpotts   - refactored into class/module
!
!   input argument list:
!     grd      - grd info for ensemble
!     member   - index for ensemble member
!     ntindex  - time index for ensemble
!
!   output argument list:
!     atm_bundle - atm bundle w/ fields for ensemble member
!     iret       - return code, 0 for successful read.
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

    use kinds, only: i_kind,r_kind,r_single
    use general_sub2grid_mod, only: sub2grid_info
    use hybrid_ensemble_parameters, only: n_ens,ens_fast_read
    use hybrid_ensemble_parameters, only: grd_ens
    use gsi_bundlemod, only: gsi_bundle
    use control_vectors, only: nc2d,nc3d

    implicit none

    ! Declare passed variables
    class(get_arw_ensmod_class), intent(inout) :: this
    type(sub2grid_info), intent(in   ) :: grd
    integer(i_kind),     intent(in   ) :: ntindex
    type(gsi_bundle),    intent(inout) :: atm_bundle(:)
    integer(i_kind),     intent(  out) :: iret

    ! Declare internal variables
    character(len=*),parameter :: myname='get_user_ens_arw'
    real(r_single),allocatable :: en_loc3(:,:,:,:)
    integer(i_kind) :: m_cvars2d(nc2d),m_cvars3d(nc3d)

    integer(i_kind) :: n
    real(r_kind),allocatable :: clons(:),slons(:)

    associate( this => this ) ! eliminates warning for unused dummy argument needed for binding
    end associate

    if ( ens_fast_read ) then
       allocate(en_loc3(grd_ens%lat2,grd_ens%lon2,nc2d+nc3d*grd_ens%nsig,n_ens))
       allocate(clons(grd_ens%nlon),slons(grd_ens%nlon))
       call get_user_ens_arw_fastread_(ntindex,en_loc3,m_cvars2d,m_cvars3d, &
                         grd_ens%lat2,grd_ens%lon2,grd_ens%nsig, &
                         nc2d,nc3d,n_ens,iret,clons,slons)
       do n=1,n_ens
          call move2bundle_(grd,en_loc3(:,:,:,n),atm_bundle(n), &
                            m_cvars2d,m_cvars3d,iret,clons,slons)
       end do
       deallocate(en_loc3,clons,slons)
    !else
    !   do n = 1,n_ens
    !      call get_user_ens_arw_member_(grd,n,ntindex,atm_bundle(n),iret)
    !   end do
    endif

    return

end subroutine get_user_ens_arw

subroutine get_user_ens_arw_fastread_(ntindex,en_loc3,m_cvars2d,m_cvars3d, &
                                lat2in,lon2in,nsigin,nc2din,nc3din,n_ensin,iret,clons,slons)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    get_user_ens_arw_fastread_
!   prgmmr: mahajan          org: emc/ncep            date: 2016-06-30
!
! abstract: Read in GFS ensemble members in to GSI ensemble.  This is the
!           version which reads all ensemble members simultaneously in
!           parallel to n_ens processors.  This is followed by a scatter
!           to subdomains on all processors.  This version will only work
!           if n_ens <= npe, where npe is the total number of processors
!           available.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!      NOTE:  In this version, just copy pole row values to halo rows beyond
!      pole.  Verify that that is what is done in current GSI.  If so, then
!      postpone proper values for halo points beyond poles.  Main goal here is
!      to get bit-wise identical results between fast ensemble read and current
!      ensemble read.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!
! program history log:
!   2016-06-30  mahajan  - initial code
!   2016-10-11  parrish  - create fast parallel code
!
!   input argument list:
!     ntindex  - time index for ensemble
!     ens_atm_bundle - atm bundle w/ fields for ensemble
!
!   output argument list:
!     ens_atm_bundle - atm bundle w/ fields for ensemble
!     iret           - return code, 0 for successful read.
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

    use mpimod, only: mpi_comm_world,ierror,mpi_real8,mpi_integer4,mpi_max
    use kinds, only: i_kind,r_single,r_kind
    use constants, only: zero
    use general_sub2grid_mod, only: sub2grid_info
    use gsi_4dvar, only: ens_fhrlevs
    use hybrid_ensemble_parameters, only: n_ens,grd_ens
    use control_vectors, only: cvars2d,cvars3d,nc2d,nc3d
    use genex_mod, only: genex_info,genex_create_info,genex,genex_destroy_info

    implicit none

    ! Declare passed variables
    integer(i_kind),     intent(in   ) :: ntindex
    real(r_single),      intent(inout) :: en_loc3(lat2in,lon2in,nc2din+nc3din*nsigin,n_ensin)
    integer(i_kind),     intent(inout) :: m_cvars2d(nc2din),m_cvars3d(nc3din)
    integer(i_kind),     intent(in   ) :: lat2in,lon2in,nsigin,nc2din,nc3din,n_ensin
    integer(i_kind),     intent(  out) :: iret
    real(r_kind),        intent(inout) :: clons(grd_ens%nlon),slons(grd_ens%nlon)


    ! Declare internal variables
    character(len=*),parameter :: myname='get_user_ens_arw_fastread_'
    character(len=70) :: filename
    integer(i_kind) :: i,ii,j,jj,k,n
    integer(i_kind) :: io_pe,n_io_pe_s,n_io_pe_e,n_io_pe_em,i_ens
    integer(i_kind) :: ip,ips,ipe,jps,jpe
    integer(i_kind) :: ias,iae,iasm,iaem,iaemz,jas,jae,jasm,jaem,jaemz
    integer(i_kind) :: kas,kae,kasm,kaem,kaemz,mas,mae,masm,maem,maemz
    integer(i_kind) :: ibs,ibe,ibsm,ibem,ibemz,jbs,jbe,jbsm,jbem,jbemz
    integer(i_kind) :: kbs,kbe,kbsm,kbem,kbemz,mbs,mbe,mbsm,mbem,mbemz
    integer(i_kind) :: n2d
    integer(i_kind) :: nlon,nlat,nsig
    type(genex_info) :: s_a2b
    real(r_single),allocatable :: en_full(:,:,:,:)
    real(r_single),allocatable :: en_loc(:,:,:,:)
    integer(i_kind),allocatable :: m_cvars2dw(:),m_cvars3dw(:)
    integer(i_kind) base_pe,base_pe0

    iret = 0

    nlat=grd_ens%nlat
    nlon=grd_ens%nlon
    nsig=grd_ens%nsig

    ! write out contents of cvars2d, cvars3d

    !if (mype == 0 ) then
    !    write(6,*) ' in get_user_ens_fastread_,cvars2d=',(trim(cvars2d(i)),i=1,2)
    !    write(6,*) ' in get_user_ens_fastread_,cvars3d=',(trim(cvars3d(i)),i=1,6)
    !endif

    !  set up partition of available processors for parallel read
    if ( n_ens > npe ) &
        call die(myname_, ': ***ERROR*** CANNOT READ ENSEMBLE  n_ens > npe, increase npe >= n_ens', 99)

    call ens_io_partition_(n_ens,io_pe,n_io_pe_s,n_io_pe_e,n_io_pe_em,i_ens)

    ! setup communicator for scatter to subdomains:

    ! first, define gsi subdomain boundaries in global units:

    ip=1   !  halo width is hardwired at 1
    ips=grd_ens%istart(mype+1)
    ipe=ips+grd_ens%lat1-1
    jps=grd_ens%jstart(mype+1)
    jpe=jps+grd_ens%lon1-1


!!!!!!!!!!!!NOTE--FOLLOWING HAS MANY VARS TO BE DEFINED--NLAT,NLON ARE ENSEMBLE DOMAIN DIMS
!!!!!!!!for example,  n2d = nc3d*nsig + nc2d

    n2d=nc3d*grd_ens%nsig+nc2d
    ias=1 ; iae=0 ; jas=1 ; jae=0 ; kas=1 ; kae=0 ; mas=1 ; mae=0
    if(mype==io_pe) then
       ias=1 ; iae=nlat
       jas=1 ; jae=nlon
       kas=1 ; kae=n2d
       mas=n_io_pe_s ; mae=n_io_pe_em
    endif
    iasm=ias ; iaem=iae ; jasm=jas ; jaem=jae ; kasm=kas ; kaem=kae ; masm=mas ; maem=mae

    ibs =ips    ; ibe =ipe    ; jbs =jps    ; jbe =jpe
    ibsm=ibs-ip ; ibem=ibe+ip ; jbsm=jbs-ip ; jbem=jbe+ip
    kbs =1   ; kbe =n2d ; mbs =1   ; mbe =n_ens
    kbsm=kbs ; kbem=kbe ; mbsm=mbs ; mbem=mbe
    iaemz=max(iasm,iaem) ; jaemz=max(jasm,jaem)
    kaemz=max(kasm,kaem) ; maemz=max(masm,maem)
    ibemz=max(ibsm,ibem) ; jbemz=max(jbsm,jbem)
    kbemz=max(kbsm,kbem) ; mbemz=max(mbsm,mbem)
    call genex_create_info(s_a2b,ias ,iae ,jas ,jae ,kas ,kae ,mas ,mae , &
                                 ibs ,ibe ,jbs ,jbe ,kbs ,kbe ,mbs ,mbe , &
                                 iasm,iaem,jasm,jaem,kasm,kaem,masm,maem, &
                                 ibsm,ibem,jbsm,jbem,kbsm,kbem,mbsm,mbem)

!!  read ensembles

    allocate(en_full(iasm:iaemz,jasm:jaemz,kasm:kaemz,masm:maemz))

    write(filename,22) mas
22  format('wrf_en',i3.3)

    allocate(m_cvars2dw(nc2din),m_cvars3dw(nc3din))
    m_cvars2dw=-999
    m_cvars3dw=-999

    if ( mas == mae ) &
        call parallel_read_wrfarw_state_(en_full,m_cvars2dw,m_cvars3dw,nlon,nlat,nsig, &
                                         ias,jas,mas,mae, &
                                         iasm,iaemz,jasm,jaemz,kasm,kaemz,masm,maemz, &
                                         filename)
    base_pe0=-999
    if ( mas == 1 .and. mae == 1 ) base_pe0=mype

    call mpi_allreduce(base_pe0,base_pe,1,mpi_integer4,mpi_max,mpi_comm_world,ierror)
    call mpi_bcast(clons,grd_ens%nlon,mpi_real8,base_pe,mpi_comm_world,ierror)
    call mpi_bcast(slons,grd_ens%nlon,mpi_real8,base_pe,mpi_comm_world,ierror)

    call mpi_allreduce(m_cvars2dw,m_cvars2d,nc2d,mpi_integer4,mpi_max,mpi_comm_world,ierror)
    call mpi_allreduce(m_cvars3dw,m_cvars3d,nc3d,mpi_integer4,mpi_max,mpi_comm_world,ierror)

! scatter to subdomains:

    allocate(en_loc(ibsm:ibemz,jbsm:jbemz,kbsm:kbemz,mbsm:mbemz))

    en_loc=zero
    call genex(s_a2b,en_full,en_loc)

    deallocate(en_full)
    call genex_destroy_info(s_a2b)  ! check on actual routine name

! transfer en_loc to en_loc3

! Look to thread here OMP
    do n=1,n_ens
       do k=1,nc2d+nc3d*nsig
          jj=0
          do j=jbsm,jbem
             jj=jj+1
             ii=0
             do i=ibsm,ibem
                ii=ii+1
                en_loc3(ii,jj,k,n)=en_loc(i,j,k,n)
             enddo
          enddo
       enddo
    enddo

end subroutine get_user_ens_arw_fastread_

subroutine move2bundle_(grd,en_loc3,atm_bundle,m_cvars2d,m_cvars3d,iret,clons,slons)

!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    move2bundle  transfer 1 ensemble member to bundle
!   prgmmr: mahajan          org: emc/ncep            date: 2016-06-30
!
! abstract: transfer one ensemble member to bundle
!
! program history log:
!   2016-06-30  parrish -- copy and adapt get_user_ens_member_ to transfer 1
!                            ensemble member
!
!   input argument list:
!     grd        - grd info for ensemble
!     en_loc3    - ensemble member
!     atm_bundle - empty atm bundle
!     m_cvars2d  - maps 3rd index in en_loc3 for start of each 2d variable
!     m_cvars3d  - maps 3rd index in en_loc3 for start of each 3d variable
!
!   output argument list:
!     atm_bundle - atm bundle w/ fields for ensemble member
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

    use kinds, only: i_kind,r_kind,r_single
    use constants, only: zero,one,two,fv
    use general_sub2grid_mod, only: sub2grid_info,general_sub2grid_destroy_info
    use hybrid_ensemble_parameters, only: en_perts
    use mpeu_util, only: getindex
    use gsi_bundlemod, only: gsi_bundle
    use gsi_bundlemod, only: gsi_bundlegetpointer,gsi_bundleputvar
    use gsi_bundlemod, only : assignment(=)
    use control_vectors, only: cvars2d,cvars3d,nc2d,nc3d
    use control_vectors, only : w_exist, dbz_exist

    implicit none

    ! Declare passed variables
    type(sub2grid_info), intent(in   ) :: grd
    real(r_single),      intent(in   ) :: en_loc3(grd%lat2,grd%lon2,nc2d+nc3d*grd%nsig)
    type(gsi_bundle),    intent(inout) :: atm_bundle
    integer(i_kind),     intent(in   ) :: m_cvars2d(nc2d),m_cvars3d(nc3d)
    integer(i_kind),     intent(  out) :: iret
    real(r_kind),        intent(in   ) :: clons(grd%nlon),slons(grd%nlon)

    ! Declare internal variables
    character(len=*),parameter :: myname='move2bundle_'
    character(len=70) :: filename

    integer(i_kind) :: ierr
    integer(i_kind) :: im,jm,km,m,k
    real(r_kind),pointer,dimension(:,:)   :: ps
    !real(r_kind),pointer,dimension(:,:)   :: sst
    real(r_kind),pointer,dimension(:,:,:) :: u
    real(r_kind),pointer,dimension(:,:,:) :: v
    real(r_kind),pointer,dimension(:,:,:) :: tv
    real(r_kind),pointer,dimension(:,:,:) :: q
    real(r_kind),pointer,dimension(:,:,:) :: oz
    real(r_kind),pointer,dimension(:,:,:) :: cwmr
    real(r_kind),pointer,dimension(:,:,:) :: w,dbz,qg,qi,qr,qs,qnc,qni,qnr
    real(r_single),allocatable,dimension(:,:)   :: scr2
    real(r_single),allocatable,dimension(:,:,:) :: scr3
    type(sub2grid_info) :: grd2d,grd3d
    real(r_kind),parameter :: r0_001 = 0.001_r_kind
    integer(i_kind):: i_radar_qr,i_radar_qg

  !    Determine if qr and qg are control variables for radar data assimilation,
     i_radar_qr=0
     i_radar_qg=0
     i_radar_qr=getindex(cvars3d,'qr')
     i_radar_qg=getindex(cvars3d,'qg')

    im = en_perts(1,1)%grid%im
    jm = en_perts(1,1)%grid%jm
    km = en_perts(1,1)%grid%km

    allocate(scr2(im,jm))
    allocate(scr3(im,jm,km))

!   initialize atm_bundle to zero

    atm_bundle=zero

    call gsi_bundlegetpointer(atm_bundle,'ps',ps,  ierr); iret = ierr
    !call gsi_bundlegetpointer(atm_bundle,'sst',sst, ierr); iret = ierr
    call gsi_bundlegetpointer(atm_bundle,'sf',u ,  ierr); iret = ierr + iret
    call gsi_bundlegetpointer(atm_bundle,'vp',v ,  ierr); iret = ierr + iret
    call gsi_bundlegetpointer(atm_bundle,'t' ,tv,  ierr); iret = ierr + iret
    call gsi_bundlegetpointer(atm_bundle,'q' ,q ,  ierr); iret = ierr + iret
    !call gsi_bundlegetpointer(atm_bundle,'oz',oz,  ierr); iret = ierr + iret
    call gsi_bundlegetpointer(atm_bundle,'ql',cwmr,ierr); iret = ierr + iret
    if ( i_radar_qr > 0 .and. i_radar_qg > 0 ) then
      if(w_exist) call gsi_bundlegetpointer(atm_bundle,'w',w ,  ierr); iret = ierr + iret
      if(dbz_exist) call gsi_bundlegetpointer(atm_bundle,'dbz',dbz ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qg',qg ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qi',qi ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qr',qr ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qs',qs ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qnc',qnc ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qni',qni ,  ierr); iret = ierr + iret
      call gsi_bundlegetpointer(atm_bundle,'qnr',qnr ,  ierr); iret = ierr + iret
    end if
    if ( iret /= 0 ) then
       if ( mype == 0 ) then
          write(6,'(A)') trim(myname) // ': ERROR!'
          write(6,'(A)') trim(myname) // ': For now, GFS requires all MetFields: ps,u,v,(sf,vp)tv,q,oz,cw'
          write(6,'(A)') trim(myname) // ': but some have not been found. Aborting ... '
       endif
       goto 100
    endif

    do m=1,nc2d
       scr2(:,:)=en_loc3(:,:,m_cvars2d(m))
       if(trim(cvars2d(m))=='ps') then
          ps=scr2
       endif
    !  if(trim(cvars2d(m))=='sst') sst=scr2    !  no sst for now
    enddo

! u,v,t,q,w,dbz,qr,qs,qi,qg,qc,qnc,qni,qnr
    do m=1,nc3d
       do k=1,km
          scr3(:,:,k)=en_loc3(:,:,m_cvars3d(m)+k-1)
       enddo
       if(trim(cvars3d(m))=='sf')  u    = scr3
       if(trim(cvars3d(m))=='vp')  v    = scr3
       if(trim(cvars3d(m))=='t')   tv   = scr3
       if(trim(cvars3d(m))=='q')   q    = scr3
       !if(trim(cvars3d(m))=='oz')  oz   = scr3
       if ( i_radar_qr > 0 .and. i_radar_qg > 0 ) then
         if(w_exist   .and. trim(cvars3d(m))=='w')   w   = scr3
         if(dbz_exist .and. trim(cvars3d(m))=='dbz') dbz = scr3
         if(trim(cvars3d(m))=='qr')  qr   = scr3
         if(trim(cvars3d(m))=='qs')  qs   = scr3
         if(trim(cvars3d(m))=='qi')  qi   = scr3
         if(trim(cvars3d(m))=='qg')  qg   = scr3
         if(trim(cvars3d(m))=='ql')  cwmr = scr3
         if(trim(cvars3d(m))=='qnc')  qnc = scr3
         if(trim(cvars3d(m))=='qni')  qni = scr3
         if(trim(cvars3d(m))=='qnr')  qnr = scr3
       end if
    enddo

!   convert ps from Pa to cb
!    ps=r0_001*ps
!   convert t to virtual temperature
!    tv=tv*(one+fv*q)

!--- now update pole values of atm_bundle using general_sub2grid (so halos also
!       automatically updated.

    call create_grd23d_(grd2d,1)
    call create_grd23d_(grd3d,grd%nsig)

    call update_scalar_poles_(grd2d,ps)
    !call update_vector_poles_(grd3d,u,v)
    call update_scalar_poles_(grd3d,u)
    call update_scalar_poles_(grd3d,v)
    call update_scalar_poles_(grd3d,tv)
    call update_scalar_poles_(grd3d,q)
    !call update_scalar_poles_(grd3d,oz)
    if ( i_radar_qr > 0 .and. i_radar_qg > 0 ) then
      if(w_exist) call update_scalar_poles_(grd3d,w)
      if(dbz_exist) call update_scalar_poles_(grd3d,dbz)
      call update_scalar_poles_(grd3d,qg)
      call update_scalar_poles_(grd3d,qi)
      call update_scalar_poles_(grd3d,qr)
      call update_scalar_poles_(grd3d,qs)
      call update_scalar_poles_(grd3d,cwmr)
      call update_scalar_poles_(grd3d,qnr)
      call update_scalar_poles_(grd3d,qni)
      call update_scalar_poles_(grd3d,qnc)
    end if

    call gsi_bundleputvar(atm_bundle,'ps',ps,  ierr); iret = ierr
    !call gsi_bundleputvar(atm_bundle,'sst',sst,ierr); iret = ierr + iret  ! no sst for now
    call gsi_bundleputvar(atm_bundle,'sf',u ,  ierr); iret = ierr + iret
    call gsi_bundleputvar(atm_bundle,'vp',v ,  ierr); iret = ierr + iret
    call gsi_bundleputvar(atm_bundle,'t' ,tv,  ierr); iret = ierr + iret
    call gsi_bundleputvar(atm_bundle,'q' ,q ,  ierr); iret = ierr + iret
    !call gsi_bundleputvar(atm_bundle,'oz',oz,  ierr); iret = ierr + iret
    if ( i_radar_qr > 0 .and. i_radar_qg > 0 ) then
      if(w_exist) call gsi_bundleputvar(atm_bundle,'w',w ,  ierr); iret = ierr + iret
      if(dbz_exist) call gsi_bundleputvar(atm_bundle,'dbz',dbz ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qg',qg ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qi',qi ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qr',qr ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qs',qs ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'ql',cwmr,ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qnr',qnr ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qni',qni ,  ierr); iret = ierr + iret
      call gsi_bundleputvar(atm_bundle,'qnc',qnc ,  ierr); iret = ierr + iret
    end if

    if ( iret /= 0 ) then
       if ( mype == 0 ) then
          write(6,'(A)') trim(myname) // ': ERROR!'
          write(6,'(A)') trim(myname) // ': For now, GFS needs to put all MetFields: ps,u,v,(sf,vp)tv,q,oz,cw'
          write(6,'(A)') trim(myname) // ': but some have not been found. Aborting ... '
       endif
       goto 100
    endif

    call general_sub2grid_destroy_info(grd2d,grd)
    call general_sub2grid_destroy_info(grd3d,grd)

    if ( allocated(scr2) ) deallocate(scr2)
    if ( allocated(scr3) ) deallocate(scr3)

100 continue

    if ( iret /= 0 ) then
       if ( mype == 0 ) then
          write(6,'(A)') trim(myname) // ': WARNING!'
          write(6,'(3A,I5)') trim(myname) // ': Trouble reading ensemble file : ', trim(filename), ', IRET = ', iret
       endif
    endif

    return

end subroutine move2bundle_

subroutine create_grd23d_(grd23d,nvert)

    use kinds, only: i_kind
    use general_sub2grid_mod, only: sub2grid_info,general_sub2grid_create_info
    use hybrid_ensemble_parameters, only: grd_ens

    implicit none

    ! Declare local parameters

    ! Declare passed variables
    type(sub2grid_info), intent(inout) :: grd23d
    integer(i_kind),     intent(in   ) :: nvert

    ! Declare local variables
    integer(i_kind) :: inner_vars = 1
    logical :: regional = .true.

    call general_sub2grid_create_info(grd23d,inner_vars,grd_ens%nlat,grd_ens%nlon, &
                                      nvert,nvert,regional,s_ref=grd_ens)

end subroutine create_grd23d_

subroutine update_scalar_poles_(grd,s)

    use kinds, only: i_kind,r_kind
    use general_sub2grid_mod, only: sub2grid_info,general_sub2grid,general_grid2sub

    implicit none

    ! Declare passed variables
    type(sub2grid_info), intent(in   ) :: grd
    real(r_kind),        intent(inout) :: s(grd%lat2,grd%lon2,grd%num_fields)

    ! Declare local variables
    integer(i_kind) inner_vars,lat2,lon2,nlat,nlon,nvert,kbegin_loc,kend_loc,kend_alloc
    integer(i_kind) ii,i,j,k
    real(r_kind),allocatable:: sloc(:),work(:,:,:,:)

    lat2=grd%lat2
    lon2=grd%lon2
    nlat=grd%nlat
    nlon=grd%nlon
    nvert=grd%num_fields
    inner_vars=grd%inner_vars
    kbegin_loc=grd%kbegin_loc
    kend_loc=grd%kend_loc
    kend_alloc=grd%kend_alloc
    allocate(sloc(lat2*lon2*nvert))
    allocate(work(inner_vars,nlat,nlon,kbegin_loc:kend_alloc))
    ii=0
    do k=1,nvert
       do j=1,lon2
          do i=1,lat2
             ii=ii+1
             sloc(ii)=s(i,j,k)
          enddo
       enddo
    enddo
    call general_sub2grid(grd,sloc,work)

    do k=kbegin_loc,kend_loc
       call fillpoles_s_(work(1,:,:,k),nlon,nlat)
    enddo
    call general_grid2sub(grd,work,sloc)
    ii=0
    do k=1,nvert
       do j=1,lon2
          do i=1,lat2
             ii=ii+1
             s(i,j,k)=sloc(ii)
          enddo
       enddo
    enddo

    deallocate(sloc,work)

end subroutine update_scalar_poles_

subroutine update_vector_poles_(grd,u,v)

   use kinds, only: i_kind,r_kind
   use constants, only: zero
   use general_sub2grid_mod, only: sub2grid_info,general_sub2grid,general_grid2sub

   implicit none

   ! Declare local parameters

   ! Declare passed variables
   type(sub2grid_info)               ,intent(in   ) :: grd
   real(r_kind)                      ,intent(inout) :: u(grd%lat2,grd%lon2,grd%num_fields)
   real(r_kind)                      ,intent(inout) :: v(grd%lat2,grd%lon2,grd%num_fields)

   ! Declare local variables
   integer(i_kind) inner_vars,lat2,lon2,nlat,nlon,nvert,kbegin_loc,kend_loc,kend_alloc
   integer(i_kind) ii,i,j,k
   real(r_kind),allocatable:: uloc(:),uwork(:,:,:,:)
   real(r_kind),allocatable:: vloc(:),vwork(:,:,:,:)
   real(r_kind),allocatable:: tempu(:,:),tempv(:,:)

   lat2=grd%lat2
   lon2=grd%lon2
   nlat=grd%nlat
   nlon=grd%nlon
   nvert=grd%num_fields
   inner_vars=grd%inner_vars
   kbegin_loc=grd%kbegin_loc
   kend_loc=grd%kend_loc
   kend_alloc=grd%kend_alloc
   allocate(uloc(lat2*lon2*nvert))
   allocate(vloc(lat2*lon2*nvert))
   allocate(uwork(inner_vars,nlat,nlon,kbegin_loc:kend_alloc))
   allocate(vwork(inner_vars,nlat,nlon,kbegin_loc:kend_alloc))
   allocate(tempu(nlat,nlon),tempv(nlat,nlon))
   uwork=zero ; vwork=zero ; uloc=zero ; vloc=zero
   ii=0
   do k=1,nvert
      do j=1,lon2
         do i=1,lat2
            ii=ii+1
            uloc(ii)=u(i,j,k)
            vloc(ii)=v(i,j,k)
         enddo
      enddo
   enddo
   call general_sub2grid(grd,uloc,uwork)
   call general_sub2grid(grd,vloc,vwork)

   do k=kbegin_loc,kend_loc
      do j=1,nlon
         do i=1,nlat
            tempu(i,j)=uwork(1,i,j,k)
            tempv(i,j)=vwork(1,i,j,k)
         enddo
      enddo
      call fillpoles_v_(tempu,tempv,nlon,nlat)
      do j=1,nlon
         do i=1,nlat
            uwork(1,i,j,k)=tempu(i,j)
            vwork(1,i,j,k)=tempv(i,j)
         enddo
      enddo
   enddo
   call general_grid2sub(grd,uwork,uloc)
   call general_grid2sub(grd,vwork,vloc)
   ii=0
   do k=1,nvert
      do j=1,lon2
         do i=1,lat2
            ii=ii+1
            u(i,j,k)=uloc(ii)
            v(i,j,k)=vloc(ii)
         enddo
      enddo
   enddo

   deallocate(uloc,uwork,tempu)
   deallocate(vloc,vwork,tempv)

end subroutine update_vector_poles_

subroutine ens_io_partition_(n_ens,io_pe,n_io_pe_s,n_io_pe_e,n_io_pe_em,i_ens)

!     do computation on all processors, then assign final local processor
!     values.

      use kinds, only: r_kind,i_kind
      use constants, only: half
      implicit none

!     Declare passed variables
      integer(i_kind),intent(in   ) :: n_ens
      integer(i_kind),intent(  out) :: io_pe,n_io_pe_s,n_io_pe_e,n_io_pe_em,i_ens

!     Declare local variables
      integer(i_kind) :: io_pe0(n_ens)
      integer(i_kind) :: iskip,jskip,nextra,ipe,n
      integer(i_kind) :: nsig

      i_ens=-1
      nsig=1
      iskip=npe/n_ens
      nextra=npe-iskip*n_ens
      jskip=iskip
      io_pe=-1
      io_pe0=-1
      n_io_pe_s=1
      n_io_pe_e=0

      ipe=0
      do n=1,n_ens
         io_pe0(n)=ipe
         if(n <= nextra) then
            jskip=iskip+1
         else
            jskip=iskip
         endif
         ipe=ipe+jskip
      enddo
      do n=1,n_ens
         if(mype==0) write(6,'(2(a,1x,i5,1x))') 'reading ensemble member', n,  'on pe', io_pe0(n)
      enddo

      do n=1,n_ens
         if(mype==io_pe0(n)) then
            i_ens=n
            io_pe=mype
            n_io_pe_s=(n-1)*nsig+1
            n_io_pe_e=n*nsig
         endif
      enddo
      n_io_pe_em=max(n_io_pe_s,n_io_pe_e)

end subroutine ens_io_partition_

subroutine parallel_read_wrfarw_state_(en_full,m_cvars2d,m_cvars3d,nlon,nlat,nsig, &
                                        ias ,jas ,mas ,mae  , &
                                        iasm,iaemz,jasm,jaemz,kasm,kaemz,masm,maemz, &
                                        filename)

   use kinds, only: i_kind,r_kind,r_single
   use constants, only: r60,r3600,zero,one,half,pi,deg2rad
   use control_vectors, only: cvars2d,cvars3d,nc2d,nc3d
   use mpeu_util, only: getindex
   use control_vectors, only : w_exist, dbz_exist
   use general_sub2grid_mod, only: sub2grid_info

   implicit none

   ! Declare local parameters

   integer(i_kind)                 :: nc3d_r

   ! Declare passed variables
   integer(i_kind),  intent(in   ) :: nlon,nlat,nsig
   integer(i_kind),  intent(in   ) :: ias ,jas ,mas ,mae
   integer(i_kind),  intent(in   ) :: iasm,iaemz,jasm,jaemz,kasm,kaemz,masm,maemz
   integer(i_kind),  intent(inout) :: m_cvars2d(nc2d),m_cvars3d(nc3d)
   real(r_single),   intent(inout) :: en_full(iasm:iaemz,jasm:jaemz,kasm:kaemz,masm:maemz)
   character(len=*), intent(in   ) :: filename

   ! Declare local variables
   integer(i_kind) i,ii,j,jj,k,lonb,latb,levs
   integer(i_kind) k2,k3,k3u,k3v,k3t,k3q,k3cw,k3oz,kf
   integer(i_kind) iret,istop
   integer(i_kind),dimension(7):: idate
   integer(i_kind),dimension(4):: odate
   integer(i_kind) nframe,nfhour,nfminute,nfsecondn,nfsecondd
   integer(i_kind) nrec
   character(len=120) :: myname_ = 'parallel_read_wrfarw_state_'
   character(len=1)   :: null = ' '
   real(r_single),allocatable,dimension(:) :: work
   real(r_single),allocatable ::  temp3(:,:,:,:),temp2(:,:,:)

  !    Determine if qr and qg are control variables for radar data assimilation,
     i_radar_qr=0
     i_radar_qg=0
     i_radar_qr=getindex(cvars3d,'qr')
     i_radar_qg=getindex(cvars3d,'qg')


   allocate(work(nlon*nlat))
   allocate(temp3(nlat,nlon,nsig,nc3d))
   allocate(temp2(nlat,nlon,nc2d))
   
   temp2 = zero
   temp3 = zero

   open(99, file=trim(filename),form='binary',convert='big_endian')
     read(99)work
     call move1_(work,temp2(:,:,1),nlon,nlat)
     
     do k3=1,nc3d
     do k=1,nsig
       read(99)work
       call move1_(work,temp3(:,:,k,k3),nlon,nlat)
     end do
     end do
   close(99)

! u,v,t,q,w,dbz,qr,qs,qi,qg,qc,qnc,qni,qnr

!   convert T to Tv:    postpone this calculation
!  temp3(:,:,:,k3t)=temp3(:,:,:,k3t)*(one+fv*temp3(:,:,:,k3q))

   deallocate(work)

!  move temp2,temp3 to en_full
   kf=0
   do k3=1,nc3d
      m_cvars3d(k3)=kf+1
      do k=1,nsig
         kf=kf+1
         jj=jas-1
         do j=1,nlon
            jj=jj+1
            ii=ias-1
            do i=1,nlat
               ii=ii+1
               en_full(ii,jj,kf,mas)=temp3(i,j,k,k3)
            enddo
         enddo
      enddo
   enddo
   do k2=1,nc2d
      m_cvars2d(k2)=kf+1
      kf=kf+1
      jj=jas-1
      do j=1,nlon
         jj=jj+1
         ii=ias-1
         do i=1,nlat
            ii=ii+1
            en_full(ii,jj,kf,mas)=temp2(i,j,k2)
         enddo
      enddo
   enddo

   deallocate(temp3)
   deallocate(temp2)

end subroutine parallel_read_wrfarw_state_

subroutine fillpoles_s_(temp,nlon,nlat)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    fillpoles_s_  make pole points average of nearest pole row
!   prgmmr: parrish          org: emc/ncep            date: 2016-10-14
!
! abstract:  make pole points average of nearest pole row.
!
! program history log:
!   2016-10-14  parrish  - initial code
!
!   input argument list:
!     temp     - 2-d input array containing gsi global horizontal field
!     nlon     - number of gsi/gfs longitudes
!     nlat     - number of gsi latitudes (nlat-2 is gfs--no pole points)
!
!   output argument list:
!     temp     - 2-d output array containing gsi global horizontal field with
!                    pole values set equal to average of adjacent pole rows
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

   use kinds, only: i_kind,r_kind
   use constants, only: zero,one

   integer(i_kind),intent(in   ) :: nlon,nlat
   real(r_kind), intent(inout) :: temp(nlat,nlon)

   integer(i_kind) nlatm1,i
   real(r_kind) sumn,sums,rnlon

!  Compute mean along southern and northern latitudes
   sumn=zero
   sums=zero
   nlatm1=nlat-1
   do i=1,nlon
      sumn=sumn+temp(nlatm1,i)
      sums=sums+temp(2,i)
   end do
   rnlon=one/float(nlon)
   sumn=sumn*rnlon
   sums=sums*rnlon

!  Load means into local work array
   do i=1,nlon
      temp(1,i)   =sums
      temp(nlat,i)=sumn
   end do

end subroutine fillpoles_s_

subroutine fillpoles_v_(tempu,tempv,nlon,nlat,clons,slons)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    fillpoles_v_  create vector values at pole from nearest pole row
!   prgmmr: parrish          org: emc/ncep            date: 2016-10-14
!
! abstract:  create vector values at pole from nearest pole row.
!
! program history log:
!   2016-10-14  parrish  - initial code
!
!   input argument list:
!     tempu    - 2-d input array containing gsi global horizontal westerly vector component
!     tempv    - 2-d input array containing gsi global horizontal easterly vector component
!     nlon     - number of gsi/gfs longitudes
!     nlat     - number of gsi latitudes (nlat-2 is gfs--no pole points)
!
!   output argument list:
!     temp     - 2-d output array containing gsi global horizontal field with
!                    pole values set equal to average of adjacent pole rows
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

   use kinds, only: i_kind,r_kind
   use constants, only: zero

   integer(i_kind),intent(in   ) :: nlon,nlat
   real(r_kind),   intent(inout) :: tempu(nlat,nlon),tempv(nlat,nlon)
   real(r_kind),   intent(in   ) :: clons(nlon),slons(nlon)

   integer(i_kind) i
   real(r_kind) polnu,polnv,polsu,polsv

!  Compute mean along southern and northern latitudes
   polnu=zero
   polnv=zero
   polsu=zero
   polsv=zero
   do i=1,nlon
      polnu=polnu+tempu(nlat-1,i)*clons(i)-tempv(nlat-1,i)*slons(i)
      polnv=polnv+tempu(nlat-1,i)*slons(i)+tempv(nlat-1,i)*clons(i)
      polsu=polsu+tempu(2,i     )*clons(i)+tempv(2,i     )*slons(i)
      polsv=polsv+tempu(2,i     )*slons(i)-tempv(2,i     )*clons(i)
   end do
   polnu=polnu/float(nlon)
   polnv=polnv/float(nlon)
   polsu=polsu/float(nlon)
   polsv=polsv/float(nlon)
   do i=1,nlon
      tempu(nlat,i)= polnu*clons(i)+polnv*slons(i)
      tempv(nlat,i)=-polnu*slons(i)+polnv*clons(i)
      tempu(1,i   )= polsu*clons(i)+polsv*slons(i)
      tempv(1,i   )= polsu*slons(i)-polsv*clons(i)
   end do

end subroutine fillpoles_v_

subroutine move1_(work,temp,nlon,nlat)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    move1_   move gfs lon lat array to gsi lat lon array
!   prgmmr: parrish          org: emc/ncep            date: 2016-10-14
!
! abstract: move gfs lon lat array to gsi lat lon array.
!
! program history log:
!   2016-10-14  parrish  - initial code
!
!   input argument list:
!     work     - 1-d input array containing gfs horizontal field
!     nlon     - number of gsi/gfs longitudes
!     nlat     - number of gsi latitudes (nlat-2 is gfs--no pole points)
!
!   output argument list:
!     temp     - 2-d output array containing gsi global horizontal field
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

    use kinds, only: i_kind,r_kind,r_single
    use constants, only: zero

    implicit none

    integer(i_kind),intent(in   ) :: nlon,nlat
    real(r_single), intent(in   ) :: work(nlon*(nlat-2))
    real(r_single), intent(  out) :: temp(nlat,nlon)

    integer(i_kind) ii,i,j

    ii=0
    temp(1,:)=zero
    temp(nlat,:)=zero
    do i=nlat-1,2,-1
       do j=1,nlon
          ii=ii+1
          temp(i,j)=work(ii)
       enddo
    enddo

end subroutine move1_

subroutine get_user_ens_arw_member_(grd,member,ntindex,atm_bundle,iret)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    get_user_ens_member_
!   prgmmr: mahajan          org: emc/ncep            date: 2016-06-30
!
! abstract: Read in GFS ensemble members in to GSI ensemble.
!
! program history log:
!   2016-06-30  mahajan  - initial code
!
!   input argument list:
!     grd      - grd info for ensemble
!     member   - index for ensemble member
!     ntindex  - time index for ensemble
!
!   output argument list:
!     atm_bundle - atm bundle w/ fields for ensemble member
!     iret       - return code, 0 for successful read.
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

    use kinds, only: i_kind,r_kind
    use general_sub2grid_mod, only: sub2grid_info
    use gsi_4dvar, only: ens_fhrlevs
    use hybrid_ensemble_parameters, only: ensemble_path
    use hybrid_ensemble_parameters, only: uv_hyb_ens
    use hybrid_ensemble_parameters, only: sp_ens
    use gsi_bundlemod, only: gsi_bundle

    implicit none

    ! Declare passed variables
    type(sub2grid_info), intent(in   ) :: grd
    integer(i_kind),     intent(in   ) :: member
    integer(i_kind),     intent(in   ) :: ntindex
    type(gsi_bundle),    intent(inout) :: atm_bundle
    integer(i_kind),     intent(  out) :: iret

    ! Declare internal variables
    character(len=*),parameter :: myname='get_user_ens_arw_member_'
    character(len=70) :: filename
    logical :: zflag = .false.
    logical,save :: inithead = .true.

    ! if member == 0, read ensemble mean
    if ( member == 0 ) then
       write(filename,12) trim(adjustl(ensemble_path)),ens_fhrlevs(ntindex)
    else
       write(filename,22) trim(adjustl(ensemble_path)),ens_fhrlevs(ntindex),member
    endif
12  format(a,'sigf',i2.2,'_ensmean'     )
22  format(a,'sigf',i2.2,'_ens_mem',i3.3)

    call general_read_gfsatm(grd,sp_ens,sp_ens,filename,uv_hyb_ens,.false., &
            zflag,atm_bundle,inithead,iret)

    inithead = .false.

    if ( iret /= 0 ) then
        if ( mype == 0 ) then
            write(6,'(A)') 'get_user_ens_: WARNING!'
          write(6,'(3A,I5)') 'Trouble reading ensemble file : ', trim(filename), ', IRET = ', iret
       endif
    endif

    return

end subroutine get_user_ens_arw_member_

subroutine non_gaussian_ens_grid_arw(this,elats,elons)

    use kinds, only: r_kind
    use hybrid_ensemble_parameters, only: sp_ens

    implicit none

    ! Declare passed variables
    class(get_arw_ensmod_class), intent(inout) :: this
    real(r_kind), intent(out) :: elats(size(sp_ens%rlats)),elons(size(sp_ens%rlons))

    associate( this => this ) ! eliminates warning for unused dummy argument needed for binding
    end associate
    elats=sp_ens%rlats
    elons=sp_ens%rlons

    return

end subroutine non_gaussian_ens_grid_arw

end module get_arw_ensmod_mod
