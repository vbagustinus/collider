// metal-kangaroo kernel: SOTA Pollard kangaroo (RCKangaroo v4.0 algorithm) on secp256k1.
// ALL kangaroo walking (tame 1/3 + wild 2/3) happens here on the GPU:
//   - 3 jump tables (base 2^(Range/2+3), 2^(Range-10), 2^(Range-12)), even distances, affine points
//   - signed 256-bit distance accumulation (odd y -> jump negated, distance subtracted)
//   - symmetry +-y via jump negation
//   - L1S2 (size-2 loop) escape via jumps2; deep-loop escape via jumps3
//   - distinguished points: low dpMask bits of bits 224..255 of x are zero
// CPU (host) does keyhunt only: hash table on DP x, k recovery, verify.
#include <metal_stdlib>
using namespace metal;

// Field prime p = 2^256 - 2^32 - 977, big-endian 4x uint64
constant const uint64_t P0=0xFFFFFFFFFFFFFFFFULL, P1=0xFFFFFFFFFFFFFFFFULL, P2=0xFFFFFFFFFFFFFFFFULL, P3=0xFFFFFFFEFFFFFC2FULL;
constant const uint64_t PARR[4]={P0,P1,P2,P3};

struct Fe { uint64_t v[4]; }; // v[0]=MSW

inline Fe fe_add(Fe a, Fe b){ Fe r; uint64_t c=0;
  for(int i=3;i>=0;i--){ uint64_t s1=a.v[i]+c; uint64_t c1=(s1<a.v[i])?1:0; uint64_t s2=s1+b.v[i]; uint64_t c2=(s2<s1)?1:0; r.v[i]=s2; c=c1+c2; } return r; }
inline Fe fe_sub(Fe a, Fe b){ Fe r; uint64_t b2=0;
  for(int i=3;i>=0;i--){ uint64_t s1=a.v[i]-b2; uint64_t bb=(s1>a.v[i])?1:0; uint64_t s2=s1-b.v[i]; uint64_t bb2=(s2>s1)?1:0; r.v[i]=s2; b2=bb+bb2; } return r; }
inline bool fe_ge(Fe a, Fe b){ for(int i=0;i<4;i++){ if(a.v[i]!=b.v[i]) return a.v[i]>b.v[i]; } return true; }
inline Fe fe_mod(Fe a){ int g=0; while(fe_ge(a,Fe{P0,P1,P2,P3})&&g<8){ a=fe_sub(a,Fe{P0,P1,P2,P3}); g++; } return a; }

inline void mul256(uint64_t a[4], uint64_t b[4], uint64_t w[10]){
  for(int i=0;i<8;i++) w[i]=0;
  for(int i=0;i<4;i++){ uint64_t carry=0; uint64_t aw=a[i];
    for(int j=0;j<4;j++){ uint64_t bw=b[j];
      uint64_t al=aw&0xffffffffULL, ah=aw>>32, bl=bw&0xffffffffULL, bh=bw>>32;
      uint64_t ll=al*bl, lh=al*bh, hl=ah*bl, hh=ah*bh;
      uint64_t mid=(ll>>32)+(lh&0xffffffffULL)+(hl&0xffffffffULL);
      uint64_t lo=(ll&0xffffffffULL)|(mid<<32);
      uint64_t hi=(lh>>32)+(hl>>32)+(mid>>32)+hh;
      int pos=i+j;
      uint64_t cur=w[pos]+lo; uint64_t c1=(cur<lo)?1:0; w[pos]=cur;
      uint64_t cur2=w[pos+1]+hi+c1; uint64_t c2=(cur2<hi||(cur2==hi&&c1))?1:0; w[pos+1]=cur2; w[pos+2]+=c2;
    } }
}
inline int fe_cmpw(const uint64_t a[8], const uint64_t b[8]){
  for(int i=7;i>=0;i--){ if(a[i]!=b[i]) return a[i]>b[i]?1:-1; } return 0; }
inline Fe fe_mul(Fe a, Fe b){
  uint64_t aw[4]={a.v[3],a.v[2],a.v[1],a.v[0]};
  uint64_t bw[4]={b.v[3],b.v[2],b.v[1],b.v[0]}; uint64_t w[10]; mul256(aw,bw,w);
  uint32_t o[16]; for(int i=0;i<8;i++){ uint64_t word=w[i]; o[2*i]=(uint32_t)(word&0xffffffffULL); o[2*i+1]=(uint32_t)(word>>32); }
  uint64_t acc[16]; for(int i=0;i<16;i++) acc[i]=o[i];
  for(int r=0;r<12;r++){
    int any=0;
    for(int i=8;i<16;i++){
      if(acc[i]==0) continue; any=1;
      uint64_t hiw=acc[i]; acc[i]=0;
      uint64_t add=hiw*977ULL; int j=i-8; while(add){ uint64_t ss=acc[j]+(add&0xffffffffULL); acc[j]=(uint32_t)ss; add=(add>>32)+(ss>>32); if(++j>=16)break; }
      add=hiw; j=i-7; while(add){ uint64_t ss=acc[j]+(add&0xffffffffULL); acc[j]=(uint32_t)ss; add=(add>>32)+(ss>>32); if(++j>=16)break; }
    }
    if(!any) break;
  }
  uint32_t PLE[8]={0xFFFFFC2F,0xFFFFFFFE,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF};
  uint64_t P8[8]; for(int i=0;i<8;i++) P8[i]=PLE[i];
  int g=0; uint64_t a8[8]; for(int i=0;i<8;i++) a8[i]=acc[i];
  while(fe_cmpw(a8,P8)>=0 && g<64){ uint64_t b2=0; for(int i=0;i<8;i++){ uint64_t ss=(uint64_t)a8[i]-PLE[i]-b2; a8[i]=(uint32_t)ss; b2=(ss>>63); } }
  Fe r; for(int i=0;i<4;i++){ r.v[i]=((uint64_t)a8[7-2*i]<<32)|a8[6-2*i]; } return r; }
inline Fe fe_sqr(Fe a){ return fe_mul(a,a); }

inline bool fe_eq(Fe a, Fe b){ for(int i=0;i<4;i++) if(a.v[i]!=b.v[i]) return false; return true; }
inline Fe fe_modsub(Fe a, Fe b){ Fe r=fe_sub(a,b); if(fe_ge(b,a)&&!fe_eq(a,b)) r=fe_add(r,Fe{P0,P1,P2,P3}); return r; }
inline Fe fe_modadd(Fe a, Fe b){
  uint64_t c=0; Fe r;
  for(int i=3;i>=0;i--){ uint64_t s1=a.v[i]+c; uint64_t c1=(s1<a.v[i])?1:0; uint64_t s2=s1+b.v[i]; uint64_t c2=(s2<s1)?1:0; r.v[i]=s2; c=c1+c2; }
  if(c){ r=fe_add(r,Fe{0,0,0,0x1000003D1ULL}); } // a+b>=2^256: fix up 2^256 == 2^32+977 (mod p)
  if(fe_ge(r,Fe{P0,P1,P2,P3})) r=fe_sub(r,Fe{P0,P1,P2,P3});
  return r;
}

constant const Fe FE_ZERO = {{0,0,0,0}};

struct PAFF { Fe x; Fe y; };
inline bool fe_eq4(Fe a, Fe b){ return a.v[0]==b.v[0]&&a.v[1]==b.v[1]&&a.v[2]==b.v[2]&&a.v[3]==b.v[3]; }

inline Fe fe_shr1(Fe x){ Fe r; uint64_t car=0; for(int i=0;i<4;i++){ uint64_t t=x.v[i]; r.v[i]=(t>>1)|(car<<63); car=t&1; } return r; }
inline bool fe_is_odd(Fe a){ return (a.v[3]&1ULL)==1; }
inline Fe fe_half_addp(Fe x){ // (x + p) >> 1 for 0 <= x < p, 257-bit aware
  uint64_t c=0, sum[4];
  for(int i=3;i>=0;i--){ uint64_t s1=x.v[i]+c; uint64_t c1=(s1<x.v[i])?1:0; uint64_t s2=s1+PARR[i]; uint64_t c2=(s2<s1)?1:0; sum[i]=s2; c=c1+c2; }
  Fe r; uint64_t car=0;
  for(int i=0;i<4;i++){ uint64_t t=sum[i]; r.v[i]=(t>>1)|(car<<63); car=t&1; }
  r.v[0]|=(c<<63);
  return r;
}

// modular inverse via binary extended GCD (Stein's algorithm); several times fewer
// field-word ops than Fermat a^(p-2) which does 256 fe_sqr + ~250 fe_mul per inverse.
Fe fe_inv(Fe a){
  Fe u=Fe{P0,P1,P2,P3};
  Fe v=a;
  Fe x1=Fe{0,0,0,0};
  Fe x2=Fe{0,0,0,1};
  while(!fe_eq4(u,Fe{0,0,0,1}) && !fe_eq4(v,Fe{0,0,0,1})){
    while(!fe_is_odd(u)){ u=fe_shr1(u); if(fe_is_odd(x1)) x1=fe_half_addp(x1); else x1=fe_shr1(x1); }
    while(!fe_is_odd(v)){ v=fe_shr1(v); if(fe_is_odd(x2)) x2=fe_half_addp(x2); else x2=fe_shr1(x2); }
    if(fe_ge(u,v)){ u=fe_sub(u,v); x1=fe_modsub(x1,x2); }
    else          { v=fe_sub(v,u); x2=fe_modsub(x2,x1); }
  }
  return fe_eq4(v,Fe{0,0,0,1}) ? x2 : x1;
}

inline PAFF p2_double(PAFF a){
  if(a.x.v[3]==0&&a.x.v[2]==0&&a.x.v[1]==0&&a.x.v[0]==0) return a; // infinity
  Fe x2=fe_sqr(a.x);
  Fe threex2=fe_add(fe_add(x2,x2),x2);
  Fe twoy=fe_add(a.y,a.y);
  Fe lam=fe_mul(threex2, fe_inv(twoy));
  Fe nx=fe_modsub(fe_sqr(lam), fe_add(a.x,a.x));
  Fe ny=fe_modsub(fe_mul(lam, fe_modsub(a.x,nx)), a.y);
  PAFF r; r.x=nx; r.y=ny; return r;
}
inline PAFF p2_add(PAFF a, PAFF b){
  if(a.x.v[3]==0&&a.x.v[2]==0&&a.x.v[1]==0&&a.x.v[0]==0&&a.y.v[3]==0&&a.y.v[2]==0&&a.y.v[1]==0&&a.y.v[0]==0) return b; // a=infinity
  if(b.x.v[3]==0&&b.x.v[2]==0&&b.x.v[1]==0&&b.x.v[0]==0&&b.y.v[3]==0&&b.y.v[2]==0&&b.y.v[1]==0&&b.y.v[0]==0) return a; // b=infinity
  if(fe_eq4(a.x,b.x)){
    if(fe_eq4(a.y,b.y)) return p2_double(a);
    return a; // a+b = infinity (astronomically rare in random walk)
  }
  Fe dx=fe_modsub(a.x,b.x);
  Fe dxinv=fe_inv(dx);
  Fe lam=fe_mul(fe_modsub(a.y,b.y),dxinv);
  Fe nx=fe_modsub(fe_sqr(lam), fe_modadd(a.x,b.x));
  Fe ny=fe_modsub(fe_mul(lam, fe_modsub(a.x,nx)), a.y);
  PAFF r; r.x=nx; r.y=ny; return r;
}

// jump table entry: affine point (BE Fe) + unsigned LE distance
struct Jmp { uint64_t x[4]; uint64_t y[4]; uint64_t d[4]; };

inline Fe fe_from_u64s(const uint64_t w[4]){ Fe r; r.v[0]=w[0]; r.v[1]=w[1]; r.v[2]=w[2]; r.v[3]=w[3]; return r; }

inline void le256_add(uint64_t a[4], const uint64_t b[4]){
  uint64_t c=0;
  for(int i=0;i<4;i++){ uint64_t s1=a[i]+c; uint64_t c1=(s1<a[i])?1:0; uint64_t s2=s1+b[i]; uint64_t c2=(s2<s1)?1:0; a[i]=s2; c=c1+c2; }
}
inline void le256_sub(uint64_t a[4], const uint64_t b[4]){
  uint64_t b2=0;
  for(int i=0;i<4;i++){ uint64_t s1=a[i]-b2; uint64_t bb=(s1>a[i])?1:0; uint64_t s2=s1-b[i]; uint64_t bb2=(s2>s1)?1:0; a[i]=s2; b2=bb+bb2; }
}

// ---------------- jacobian EC (used only by kernelGen for d*G) ----------------
struct Jac { Fe X; Fe Y; Fe Z; };
constant const Fe GX={0x79be667ef9dcbbacULL,0x55a06295ce870b07ULL,0x029bfcdb2dce28d9ULL,0x59f2815b16f81798ULL};
constant const Fe GY={0x483ada7726a3c465ULL,0x5da4fbfc0e1108a8ULL,0xfd17b448a6855419ULL,0x9c47d08ffb10d4b8ULL};

inline Fe fe_dbl(Fe a){ return fe_mul(a,Fe{0,0,0,2}); }
inline Fe jac_x(Jac p){ Fe Z2=fe_sqr(p.Z); return fe_mul(p.X, fe_inv(Z2)); }

Jac jac_double(Jac p){
  if(p.Z.v[3]==0&&p.Z.v[2]==0&&p.Z.v[1]==0&&p.Z.v[0]==0) return p;
  Fe A=fe_sqr(p.X); Fe B=fe_sqr(p.Y); Fe C=fe_sqr(B);
  Fe D=fe_mul(fe_mul(p.X,B),Fe{0,0,0,4});
  Fe E=fe_mul(A,Fe{0,0,0,3}); Fe F=fe_sqr(E);
  Fe X3=fe_modsub(F,fe_dbl(D));
  Fe DmX3=fe_modsub(D,X3);
  Fe Y3=fe_modsub(fe_mul(E,DmX3), fe_mul(C,Fe{0,0,0,8}));
  Fe Z3=fe_dbl(fe_mul(p.Y,p.Z));
  Jac r; r.X=X3; r.Y=Y3; r.Z=Z3; return r;
}
Jac jac_add(Jac p, Jac q){
  if(p.Z.v[3]==0&&p.Z.v[2]==0&&p.Z.v[1]==0&&p.Z.v[0]==0) return q; // p=infinity
  if(q.Z.v[3]==0&&q.Z.v[2]==0&&q.Z.v[1]==0&&q.Z.v[0]==0) return p; // q=infinity
  Fe Z1Z1=fe_sqr(p.Z); Fe Z2Z2=fe_sqr(q.Z);
  Fe U1=fe_mul(p.X,Z2Z2); Fe U2=fe_mul(q.X,Z1Z1);
  Fe S1=fe_mul(fe_mul(p.Y,q.Z),Z2Z2); Fe S2=fe_mul(fe_mul(q.Y,p.Z),Z1Z1);
  Fe H=fe_modsub(U2,U1);
  Fe R=fe_modsub(S2,S1);
  if(H.v[3]==0&&H.v[2]==0&&H.v[1]==0&&H.v[0]==0) return jac_double(p);
  Fe HH=fe_sqr(H); Fe HHH=fe_mul(H,HH); Fe V=fe_mul(U1,HH);
  Fe X3=fe_modsub(fe_modsub(fe_sqr(R),HHH), fe_dbl(V));
  Fe Y3=fe_modsub(fe_mul(R,fe_modsub(V,X3)), fe_mul(S1,HHH));
  Fe Z3=fe_mul(fe_mul(p.Z,q.Z),H);
  Jac r; r.X=X3; r.Y=Y3; r.Z=Z3; return r;
}

// mixed Jacobian + affine addition (q.Z=1): saves Z2Z2, U1, and the two S1 muls
inline Jac jac_add_aff(Jac p, PAFF q){
  Fe Z1Z1=fe_sqr(p.Z);
  Fe U2=fe_mul(q.x,Z1Z1);
  Fe S2=fe_mul(fe_mul(q.y,p.Z),Z1Z1);
  Fe H=fe_modsub(U2,p.X);
  Fe R=fe_modsub(S2,p.Y);
  if(H.v[3]==0&&H.v[2]==0&&H.v[1]==0&&H.v[0]==0) return jac_double(p);
  Fe HH=fe_sqr(H); Fe HHH=fe_mul(H,HH); Fe V=fe_mul(p.X,HH);
  Fe X3=fe_modsub(fe_modsub(fe_sqr(R),HHH), fe_dbl(V));
  Fe Y3=fe_modsub(fe_mul(R,fe_modsub(V,X3)), fe_mul(p.Y,HHH));
  Fe Z3=fe_mul(p.Z,H);
  Jac r; r.X=X3; r.Y=Y3; r.Z=Z3; return r;
}
// ---------------- kernelGen: compute start point d*G (+PntWild for wild) ----------------
kernel void kernelGen(device const uint64_t* startDist [[buffer(0)]],
                      device const PAFF* pntWild [[buffer(1)]],
                      device Jac* kang [[buffer(2)]],
                      device uint64_t* dist [[buffer(3)]],
                      device uint64_t* histBuf [[buffer(4)]],
                      constant uint& tameCut [[buffer(5)]],
                      constant uint& kangCnt [[buffer(6)]],
                      uint tid [[thread_position_in_grid]]) {
  if(tid>=kangCnt) return;
  uint64_t d[4];
  for(int i=0;i<4;i++){ d[i]=startDist[tid*4+i]; dist[tid*4+i]=d[i]; }
  Jac R; R.X=FE_ZERO; R.Y=FE_ZERO; R.Z=FE_ZERO;
  Jac Q; Q.X=GX; Q.Y=GY; Q.Z=FE_ZERO; Q.Z.v[3]=1;
  int top=255; while(top>=0 && !((d[top>>6]>>(top&63))&1ULL)) top--;
  PAFF p; p.x=FE_ZERO; p.y=FE_ZERO;
  if(top>=0){
    for(int i=top;i>=0;i--){
      if(!(R.Z.v[3]==0&&R.Z.v[2]==0&&R.Z.v[1]==0&&R.Z.v[0]==0)) R=jac_double(R);
      if((d[i>>6]>>(i&63))&1ULL) R=jac_add(R,Q);
    }
    Fe iz2=fe_inv(fe_sqr(R.Z));
    Fe iz=fe_mul(iz2,R.Z);
    p.x=fe_mul(R.X,iz2); p.y=fe_mul(fe_mul(R.Y,iz),iz2);
  }
  if(tid>=tameCut) p=p2_add(p,pntWild[0]);
  Jac Jout; Jout.X=p.x; Jout.Y=p.y; Jout.Z=FE_ZERO; Jout.Z.v[3]=1;
  kang[tid]=Jout;
  histBuf[tid*16]=0;
  for(int i=0;i<10;i++) histBuf[tid*16+1+i]=0;
}

// ---------------- main walk kernel (Jacobian — inverse only at distinguished points) ---------------
constant uint MD = 10;

inline Jac jac_fromJmp(Jmp J, bool neg){ // affine jump point -> Jacobian (Z=1), no inverse
  Jac r;
  r.X.v[0]=J.x[0]; r.X.v[1]=J.x[1]; r.X.v[2]=J.x[2]; r.X.v[3]=J.x[3];
  r.Y.v[0]=J.y[0]; r.Y.v[1]=J.y[1]; r.Y.v[2]=J.y[2]; r.Y.v[3]=J.y[3];
  r.Z=FE_ZERO; r.Z.v[3]=1;
  if(neg) r.Y=fe_modsub(FE_ZERO, r.Y);
  return r;
}

kernel void kangaroo(device const Jmp* jmp1 [[buffer(0)]],
                     device const Jmp* jmp2 [[buffer(1)]],
                     device const Jmp* jmp3 [[buffer(2)]],
                     device Jac* kang [[buffer(3)]],
                     device uint64_t* dist [[buffer(4)]],
                     device uint64_t* histBuf [[buffer(5)]],
                     constant uint& tameCut [[buffer(6)]],
                     constant uint& dpMask [[buffer(7)]],
                     constant uint& maxSteps [[buffer(8)]],
                     constant uint& jmpCnt [[buffer(9)]],
                     constant uint& kangCnt [[buffer(10)]],
                     constant uint& maxRec [[buffer(11)]],
                     device atomic_uint* dpCnt [[buffer(12)]],
                     device uint64_t* dpRec [[buffer(13)]],
                     uint tid [[thread_position_in_grid]]) {
  if(tid>=kangCnt) return;
  Jac P=kang[tid];
  uint64_t d[4]; for(int i=0;i<4;i++) d[i]=dist[tid*4+i];
  uint64_t hw=histBuf[tid*16];
  uint hi=(uint)(hw&0xFFFFFFFFULL), l1s2=(uint)((hw>>32)&1ULL);
  uint64_t hist[MD]; for(int i=0;i<MD;i++) hist[i]=histBuf[tid*16+1+i];

  for(uint s=0;s<maxSteps;s++){
    uint ji=(uint)(P.X.v[3]&(jmpCnt-1));
    device const Jmp* tab = l1s2? jmp2 : jmp1;
    Jmp J=tab[ji];
    bool neg=(P.Y.v[3]&1)?true:false;
    uint jm=ji; if(neg) jm|=0x80000000u;
    PAFF Jaff; Jaff.x=fe_from_u64s(J.x); Jaff.y=fe_from_u64s(J.y);
    if(neg) Jaff.y=fe_modsub(FE_ZERO, Jaff.y);
    Jac nP=jac_add_aff(P,Jaff);
    if(neg) le256_sub(d,J.d); else le256_add(d,J.d);
    // L1S2 loop detection
    uint jn=(uint)(nP.X.v[3]&(jmpCnt-1));
    if(!(nP.Y.v[3]&1)) jn|=0x80000000u;
    if(l1s2) l1s2=0; else l1s2=(jm==jn);
    // distinguished point: low dpMask bits of bits 224..255 of affine x
    Fe ax=jac_x(nP);
    if((((uint32_t)(ax.v[0]>>32))&dpMask)==0){
      uint pos=atomic_fetch_add_explicit(dpCnt,1,memory_order_relaxed);
      if(pos<maxRec){
        device uint64_t* r=dpRec+(uint64_t)pos*9;
        r[0]=ax.v[0]; r[1]=ax.v[1]; r[2]=ax.v[2]; r[3]=ax.v[3];
        r[4]=d[0]; r[5]=d[1]; r[6]=d[2]; r[7]=d[3];
        r[8]=tid;
      }
    }
    // deep-loop detection (distance low64 in history) -> escape via jumps3
    uint64_t dlow=d[0];
    bool looped=false;
    for(int k=0;k<MD;k++){ if(hist[k]==dlow){ looped=true; break; } }
    if(looped){
      uint ji3=(uint)(nP.X.v[3]&(jmpCnt-1));
      Jmp J3=jmp3[ji3];
      bool neg3=(nP.Y.v[3]&1)?true:false;
      PAFF J3aff; J3aff.x=fe_from_u64s(J3.x); J3aff.y=fe_from_u64s(J3.y);
      if(neg3) J3aff.y=fe_modsub(FE_ZERO, J3aff.y);
      nP=jac_add_aff(nP,J3aff);
      if(neg3) le256_sub(d,J3.d); else le256_add(d,J3.d);
      for(int k=0;k<MD;k++) hist[k]=0;
      hi=0;
    } else {
      hist[hi]=dlow; hi=(hi+1)%MD;
    }
    P=nP;
  }
  kang[tid]=P;
  for(int i=0;i<4;i++) dist[tid*4+i]=d[i];
  histBuf[tid*16]=((uint64_t)l1s2<<32)|hi;
  for(int i=0;i<MD;i++) histBuf[tid*16+1+i]=hist[i];
}

// ---------------- field-op self-verify (G+2G=3G, G+G=2G, G+4G=5G) ----------------
kernel void verify(device const Jac* jumpPoint, device uint64_t* out){
  Jac P0 = jumpPoint[0]; // G
  Jac P1 = jumpPoint[1]; // 2G
  Jac P2 = jumpPoint[2]; // 4G
  Jac A = jac_add(P0, P1);
  Fe Ax = jac_x(A);
  out[0]=Ax.v[0]; out[1]=Ax.v[1]; out[2]=Ax.v[2]; out[3]=Ax.v[3];
  Jac B = jac_add(P0, P0);
  Fe Bx = jac_x(B);
  out[4]=Bx.v[0]; out[5]=Bx.v[1]; out[6]=Bx.v[2]; out[7]=Bx.v[3];
  Jac C = jac_add(P0, P2);
  Fe Cx = jac_x(C);
  out[8]=Cx.v[0]; out[9]=Cx.v[1]; out[10]=Cx.v[2]; out[11]=Cx.v[3];
  out[12]=P0.X.v[0]; out[13]=P0.X.v[1]; out[14]=P0.X.v[2]; out[15]=P0.X.v[3];
  out[16]=P1.X.v[0]; out[17]=P1.X.v[1]; out[18]=P1.X.v[2]; out[19]=P1.X.v[3];
  out[20]=P2.X.v[0]; out[21]=P2.X.v[1]; out[22]=P2.X.v[2]; out[23]=P2.X.v[3];
}
