module m_gpsNode
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:	 module m_gpsNode
!   prgmmr:	 j guo <jguo@nasa.gov>
!      org:	 NASA/GSFC, Global Modeling and Assimilation Office, 610.3
!     date:	 2016-05-18
!
! abstract: class-module of obs-type gpsNode (GPS)
!
! program history log:
!   2016-05-18  j guo   - added this document block for the initial polymorphic
!                         implementation.
!
!   input argument list: see Fortran 90 style document below
!
!   output argument list: see Fortran 90 style document below
!
! attributes:
!   language: Fortran 90 and/or above
!   machine:
!
!$$$  end subprogram documentation block

! module interface:
  use obsmod, only: obs_diag
  use obsmod, only: obs_diags

  use kinds , only: i_kind,r_kind
  use mpeu_util, only: assert_,die,perr,warn,tell
  use m_obsNode, only: obsNode
  implicit none
  private

  public:: gpsNode

  type,extends(obsNode):: gpsNode
     !type(gps_ob_type),pointer :: llpoint => NULL()
     type(obs_diag), pointer :: diags => NULL()
     real(r_kind)    :: res    =0._r_kind    !  gps residual
     real(r_kind)    :: err2   =0._r_kind    !  gps error squared
     real(r_kind)    :: raterr2=0._r_kind    !  square of ratio of final obs error 
                                      !  to original obs error
     !real(r_kind)    :: time          !  observation time in sec     
     real(r_kind)    :: b      =0._r_kind    !  variational quality control parameter
     real(r_kind)    :: pg     =0._r_kind    !  variational quality control parameter
     real(r_kind)    :: wij(4) =0._r_kind    !  horizontal interpolation weights

     real(r_kind),dimension(:),pointer :: jac_q => NULL()
                                      !  q jacobian 
     real(r_kind),dimension(:),pointer :: jac_t => NULL()
                                      !  t jacobian 
     real(r_kind),dimension(:),pointer :: jac_p => NULL()
                                      !  p jacobian
     integer(i_kind),dimension(:,:),pointer :: ij  => NULL()
     !logical         :: luse          !  flag indicating if ob is used in pen.

     !integer(i_kind) :: idv,iob	      ! device id and obs index for sorting
     !real   (r_kind) :: elat, elon      ! earth lat-lon for redistribution
     !real   (r_kind) :: dlat, dlon      ! earth lat-lon for redistribution
  contains
    procedure,nopass::  mytype
    procedure::  setHop => obsNode_setHop_
    procedure::   xread => obsNode_xread_
    procedure::  xwrite => obsNode_xwrite_
    procedure:: isvalid => obsNode_isvalid_
    procedure::  gettlddp => gettlddp_

    procedure, nopass:: headerRead  => obsHeader_read_
    procedure, nopass:: headerWrite => obsHeader_write_
    procedure:: init  => obsNode_init_
    procedure:: clean => obsNode_clean_
  end type gpsNode

  public:: gpsNode_typecast
  public:: gpsNode_nextcast
        interface gpsNode_typecast; module procedure typecast_ ; end interface
        interface gpsNode_nextcast; module procedure nextcast_ ; end interface

  character(len=*),parameter:: MYNAME="m_gpsNode"

!#define CHECKSUM_VERBOSE
!#define DEBUG_TRACE
!#define NDEBUG
#include "myassert.H"
#include "mytrace.H"
contains
function typecast_(aNode) result(ptr_)
!-- cast a class(obsNode) to a type(gpsNode)
  use m_obsNode, only: obsNode
  implicit none
  type(gpsNode),pointer:: ptr_
  class(obsNode),pointer,intent(in):: aNode
  character(len=*),parameter:: myname_=MYNAME//"::typecast_"
  ptr_ => null()
  if(.not.associated(aNode)) return
  select type(aNode)
  type is(gpsNode)
    ptr_ => aNode
  class default
    call die(myname_,'unexpected type, aNode%mytype() =',aNode%mytype())
  end select
return
end function typecast_

function nextcast_(aNode) result(ptr_)
!-- cast an obsNode_next(obsNode) to a type(gpsNode)
  use m_obsNode, only: obsNode,obsNode_next
  implicit none
  type(gpsNode),pointer:: ptr_
  class(obsNode),target,intent(in):: aNode

  class(obsNode),pointer:: anode_
  anode_ => obsNode_next(aNode)
  ptr_ => typecast_(anode_)
return
end function nextcast_

function mytype()
  implicit none
  character(len=:),allocatable:: mytype
  mytype="[gpsNode]"
end function mytype

! obsNode implementations

subroutine obsHeader_read_(iunit,mobs,jread,istat)
  use gridmod, only: nsig
  implicit none
  integer(i_kind),intent(in ):: iunit
  integer(i_kind),intent(out):: mobs
  integer(i_kind),intent(out):: jread
  integer(i_kind),intent(out):: istat

  character(len=*),parameter:: myname_=myname//"::obsHeader_read"
  integer(i_kind):: msig
_ENTRY_(myname_)
  
  msig=-1
  read(iunit,iostat=istat) mobs,jread, msig
  if(istat==0 .and. msig/=nsig) then
    call perr(myname_,'unmatched dimension information, expecting nsig =',nsig)
    call perr(myname_,'                                  but read msig =',msig)
    call  die(myname_)
  endif
_EXIT_(myname_)
return
end subroutine obsHeader_read_

subroutine obsHeader_write_(junit,mobs,jwrite,jstat)
  use gridmod, only: nsig
  implicit none
  integer(i_kind),intent(in ):: junit
  integer(i_kind),intent(in ):: mobs
  integer(i_kind),intent(in ):: jwrite
  integer(i_kind),intent(out):: jstat
  
  character(len=*),parameter:: myname_=myname//"::obsHeader_write"
_ENTRY_(myname_)
  write(junit,iostat=jstat) mobs,jwrite, nsig
_EXIT_(myname_)
return
end subroutine obsHeader_write_

subroutine obsNode_init_(aNode)
  use gridmod, only: nsig
  implicit none
  class(gpsNode),intent(out):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_init_'
_ENTRY_(myname_)
  allocate(aNode%jac_q(nsig  ), &
           aNode%jac_t(nsig  ), &
           aNode%jac_p(nsig+1), &
           aNode%ij(4, nsig  )  )
_EXIT_(myname_)
return
end subroutine obsNode_init_

subroutine obsNode_clean_(aNode)
  implicit none
  class(gpsNode),intent(inout):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_clean_'
_ENTRY_(myname_)
!_TRACEV_(myname_,'%mytype() =',aNode%mytype())
    if(associated(aNode%jac_q)) deallocate(aNode%jac_q)
    if(associated(aNode%jac_t)) deallocate(aNode%jac_t)
    if(associated(aNode%jac_p)) deallocate(aNode%jac_p)
    if(associated(aNode%ij   )) deallocate(aNode%ij   )
_EXIT_(myname_)
return
end subroutine obsNode_clean_

subroutine obsNode_xread_(aNode,iunit,istat,diagLookup,skip)
  use m_obsdiagNode, only: obsdiagLookup_locate
  implicit none
  class(gpsNode) , intent(inout):: aNode
  integer(i_kind) , intent(in   ):: iunit
  integer(i_kind) , intent(  out):: istat
  type(obs_diags) , intent(in   ):: diagLookup
  logical,optional, intent(in   ):: skip

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_xread_'
  logical:: skip_
_ENTRY_(myname_)
  skip_=.false.
  if(present(skip)) skip_=skip

  istat=0
  if(skip_) then
    read(iunit,iostat=istat)
                if(istat/=0) then
                  call perr(myname_,'skipping read(%(res,err2,...)), iostat =',istat)
                  _EXIT_(myname_)
                  return
                endif

  else
    read(iunit,iostat=istat)    aNode%res    , &
                                aNode%err2   , &
                                aNode%raterr2, &
                                aNode%b      , &
                                aNode%pg     , &
                                aNode%jac_q  , & !(  nsig)
                                aNode%jac_t  , & !(  nsig)
                                aNode%jac_p  , & !(  nsig)
                                aNode%wij    , & !(4)
                                aNode%ij         !(4,nsig)
                if (istat/=0) then
                  call perr(myname_,'read(%(res,err2,...)), iostat =',istat)
                  _EXIT_(myname_)
                  return
                end if

    aNode%diags => obsdiagLookup_locate(diagLookup,aNode%idv,aNode%iob,1_i_kind)
                if(.not.associated(aNode%diags)) then
                  call perr(myname_,'obsdiagLookup_locate(), %idv =',aNode%idv)
                  call perr(myname_,'                        %iob =',aNode%iob)
                  call  die(myname_)
                endif
  endif
_EXIT_(myname_)
return
end subroutine obsNode_xread_

subroutine obsNode_xwrite_(aNode,junit,jstat)
  implicit none
  class(gpsNode),intent(in):: aNode
  integer(i_kind),intent(in   ):: junit
  integer(i_kind),intent(  out):: jstat

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_xwrite_'
_ENTRY_(myname_)

  jstat=0
  write(junit,iostat=jstat)     aNode%res    , &
                                aNode%err2   , &
                                aNode%raterr2, &
                                aNode%b      , &
                                aNode%pg     , &
                                aNode%jac_q  , & !(  nsig)
                                aNode%jac_t  , & !(  nsig)
                                aNode%jac_p  , & !(  nsig)
                                aNode%wij    , & !(4)
                                aNode%ij         !(4,nsig)
                if (jstat/=0) then
                  call perr(myname_,'write(%(res,err2,...)), iostat =',jstat)
                  _EXIT_(myname_)
                  return
                end if
_EXIT_(myname_)
return
end subroutine obsNode_xwrite_

subroutine obsNode_setHop_(aNode)
  use m_cvgridLookup, only: cvgridLookup_getiw
  use gridmod, only: nsig,latlon11
  implicit none
  class(gpsNode),intent(inout):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_setHop_'
  integer(i_kind):: k
_ENTRY_(myname_)

  ASSERT(size(aNode%ij,2)==nsig)
  ASSERT(nsig>0)

  call cvgridLookup_getiw(aNode%elat,aNode%elon,aNode%ij(:,1),aNode%wij)
  do k=2,nsig
    aNode%ij(:,k) = aNode%ij(:,1)+(k-1)*latlon11
  enddo
_EXIT_(myname_)
return
end subroutine obsNode_setHop_

function obsNode_isvalid_(aNode) result(isvalid_)
  implicit none
  logical:: isvalid_
  class(gpsNode),intent(in):: aNode

  character(len=*),parameter:: myname_=MYNAME//'::obsNode_isvalid_'
_ENTRY_(myname_)
  isvalid_=associated(aNode%diags)
_EXIT_(myname_)
end function obsNode_isvalid_

pure subroutine gettlddp_(aNode,jiter,tlddp,nob)
  use kinds, only: r_kind
  implicit none
  class(gpsNode), intent(in):: aNode
  integer(kind=i_kind),intent(in):: jiter
  real(kind=r_kind),intent(inout):: tlddp
  integer(kind=i_kind),optional,intent(inout):: nob

  tlddp = tlddp + aNode%diags%tldepart(jiter)*aNode%diags%tldepart(jiter)
  if(present(nob)) nob=nob+1
return
end subroutine gettlddp_

end module m_gpsNode
