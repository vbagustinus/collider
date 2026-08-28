// metal-kangaroo host (v2, SOTA): RCKangaroo v4.0 algorithm.
// GPU does ALL kangaroo walking (tame 1/3 + wild 2/3, kernelGen + kangaroo kernels).
// CPU does KEYHUNT ONLY: collects DP records, builds hash table on x, tries
// k-recovery on collisions, verifies k*G == Q. (No kangaroo walking on CPU.)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

typedef struct { uint32_t w[8]; } B256; // LE, w[0]=LSW
static const B256 PRIME = {0xFFFFFC2F,0xFFFFFFFE,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF};
static const B256 ORDER = {0xD25E8CD0,0x364141E0,0xAF48A03B,0x2FBAAEDC,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF}; // n

static B256 b_setu(uint64_t v){ B256 a; for(int i=0;i<8;i++){a.w[i]=(uint32_t)(v&0xffffffffULL); v>>=32;} return a; }
static int  b_iszero(B256 a){ for(int i=0;i<8;i++) if(a.w[i]) return 0; return 1; }
static int  b_cmp(B256 a,B256 b){ for(int i=7;i>=0;i--){ if(a.w[i]!=b.w[i]) return a.w[i]>b.w[i]?1:-1;} return 0; }
static B256 b_add(B256 a,B256 b){ B256 r; uint64_t c=0; for(int i=0;i<8;i++){ uint64_t s=(uint64_t)a.w[i]+b.w[i]+c; r.w[i]=(uint32_t)s; c=s>>32; } return r; }
static B256 b_sub(B256 a,B256 b){ B256 r; uint64_t b2=0; for(int i=0;i<8;i++){ uint64_t s=(uint64_t)a.w[i]-b.w[i]-b2; r.w[i]=(uint32_t)s; b2=(s>>63); } return r; }
static void b_mul(uint32_t o[16],B256 a,B256 b){ for(int i=0;i<16;i++)o[i]=0;
  for(int i=0;i<8;i++){ uint64_t carry=0; uint64_t aw=(uint64_t)a.w[i];
    for(int j=0;j<8;j++){ uint64_t bw=(uint64_t)b.w[j]; uint64_t cur=(uint64_t)o[i+j]+aw*bw+carry; o[i+j]=(uint32_t)cur; carry=cur>>32; }
    o[i+8]+=(uint32_t)carry; } }
static B256 b_modp(uint32_t o[16]){
  uint64_t acc[16]; for(int i=0;i<16;i++) acc[i]=o[i];
  for(int r=0;r<12;r++){
    int any=0;
    for(int i=8;i<16;i++){
      if(acc[i]==0) continue; any=1;
      uint64_t hiw=acc[i]; acc[i]=0;
      uint64_t add=hiw*977ULL; int j=i-8; while(add){ uint64_t s=acc[j]+(add&0xffffffffULL); acc[j]=(uint32_t)s; add=(add>>32)+(s>>32); if(++j>=16)break; }
      add=hiw; j=i-7; while(add){ uint64_t s=acc[j]+(add&0xffffffffULL); acc[j]=(uint32_t)s; add=(add>>32)+(s>>32); if(++j>=16)break; }
    }
    if(!any) break;
  }
  B256 v; for(int i=0;i<8;i++) v.w[i]=(uint32_t)acc[i];
  int g=0; while(b_cmp(v,PRIME)>=0&&g<64){ v=b_sub(v,PRIME); g++; }
  return v;
}
static B256 b_mulmod(B256 a,B256 b){ uint32_t o[16]; b_mul(o,a,b); return b_modp(o); }
static B256 b_sqrmod(B256 a){ return b_mulmod(a,a); }
static B256 b_modsub(B256 a,B256 b){ if(b_cmp(a,b)>=0) return b_sub(a,b); return b_add(a,b_sub(PRIME,b)); }
static B256 b_inv(B256 a){
  static const uint32_t e[8]={0xFFFFFC2D,0xFFFFFFFE,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF};
  B256 res=b_setu(1);
  for(int i=7;i>=0;i--) for(int bit=31;bit>=0;bit--){ res=b_sqrmod(res); if((e[i]>>bit)&1) res=b_mulmod(res,a); }
  return res;
}
// mod n reduction (any 256-bit v < 2^256 -> v < 2n, so one conditional subtract)
static B256 b_modn(B256 v){ if(b_cmp(v,ORDER)>=0) return b_sub(v,ORDER); return v; }
static B256 b_addmodn(B256 a,B256 b){ return b_modn(b_add(a,b)); }
static B256 b_submodn(B256 a,B256 b){ return b_modn(b_sub(a,b)); }
// signed residue mod n of a two's-complement 256-bit value
static B256 b_resid(B256 v){
  if(v.w[7]>>31){ B256 mag=b_sub(b_setu(0),v); if(b_iszero(mag)) return b_setu(0);
    B256 m=b_modn(mag); return b_modn(b_sub(ORDER,m)); }
  return b_modn(v);
}
static B256 b_shr1(B256 a){ uint32_t c=0; for(int i=7;i>=0;i--){ uint32_t t=a.w[i]; a.w[i]=(t>>1)|(c<<31); c=t&1; } return a; }
static B256 b_halfmodn(B256 v){ if(v.w[0]&1) v=b_add(v,ORDER); return b_shr1(v); }

// 256-bit unsigned divide by a small (<=2^34) constant — used for fractional subrange offsets
static B256 b_divu(B256 a, uint64_t b){
  if(b==0) return a;
  B256 q={0}, rem={0}, B=b_setu(b);
  for(int i=7;i>=0;i--) for(int bit=31;bit>=0;bit--){
    rem=b_add(rem,rem);
    if((a.w[i]>>bit)&1) rem=b_add(rem,b_setu(1));
    int qb=0;
    if(b_cmp(rem,B)>=0){ rem=b_sub(rem,B); qb=1; }
    q=b_add(q,q);
    if(qb) q=b_add(q,b_setu(1));
  }
  return q;
}

typedef struct { B256 X,Y,Z; } Jac;
static B256 P_B7;
static Jac G;
static Jac J_DOUBLE(Jac p){ if(b_iszero(p.Z))return p;
  B256 A=b_sqrmod(p.X); B256 B=b_sqrmod(p.Y); B256 C=b_sqrmod(B);
  B256 D=b_mulmod(b_setu(4), b_mulmod(p.X,B));
  B256 E=b_mulmod(b_setu(3), A); B256 F=b_sqrmod(E);
  B256 X3=b_modsub(F,b_mulmod(b_setu(2),D));
  B256 DmX3=b_modsub(D,X3);
  B256 Y3=b_modsub(b_mulmod(E,DmX3), b_mulmod(b_setu(8),C));
  B256 Z3=b_mulmod(b_setu(2), b_mulmod(p.Y,p.Z));
  Jac r; r.X=X3;r.Y=Y3;r.Z=Z3; return r; }
static Jac J_ADD(Jac p,Jac q){
  if(b_iszero(p.Z)) return q;
  if(b_iszero(q.Z)) return p;
  B256 Z1Z1=b_sqrmod(p.Z); B256 Z2Z2=b_sqrmod(q.Z);
  B256 U1=b_mulmod(p.X,Z2Z2); B256 U2=b_mulmod(q.X,Z1Z1);
  B256 S1=b_mulmod(p.Y,q.Z); S1=b_mulmod(S1,Z2Z2);
  B256 S2=b_mulmod(q.Y,p.Z); S2=b_mulmod(S2,Z1Z1);
  B256 H=b_modsub(U2,U1);
  B256 R=b_modsub(S2,S1);
  if(b_iszero(H)) return J_DOUBLE(p);
  B256 HH=b_sqrmod(H); B256 HHH=b_mulmod(H,HH); B256 V=b_mulmod(U1,HH);
  B256 X3=b_modsub(b_modsub(b_sqrmod(R),HHH), b_mulmod(b_setu(2),V));
  B256 Y3=b_modsub(b_mulmod(R,b_modsub(V,X3)), b_mulmod(S1,HHH));
  B256 Z3=b_mulmod(p.Z,q.Z); Z3=b_mulmod(Z3,H);
  Jac r; r.X=X3;r.Y=Y3;r.Z=Z3; return r;
}
static B256 J_X(Jac p){ B256 Z2=b_sqrmod(p.Z); B256 inv=b_inv(Z2); return b_mulmod(p.X,inv); }
static B256 J_Y(Jac p){ B256 Z2=b_sqrmod(p.Z); B256 invZ2=b_inv(Z2); B256 invZ=b_mulmod(invZ2,p.Z);
  B256 y=b_mulmod(p.Y,invZ); y=b_mulmod(y,invZ2); return y; }
static Jac J_MUL(Jac P,B256 k){ Jac R; memset(&R,0,sizeof R); Jac Q=P;
  for(int i=0;i<8;i++) for(int bit=0;bit<32;bit++){ if((k.w[i]>>bit)&1) R=b_iszero(R.Z)?Q:J_ADD(R,Q); Q=J_DOUBLE(Q); } return R; }
static B256 P_B7_1;
static Jac decompress_pub(const char* hex){ B256 x;
  int prefix = (hex[1]=='3')?1:0; // 02=even y, 03=odd y
  for(int i=0;i<8;i++){ unsigned long v=0; sscanf(hex+2+(7-i)*8,"%8lx",&v); x.w[i]=(uint32_t)v; } // skip "02"/"03" prefix
  B256 x3=b_sqrmod(x); x3=b_mulmod(x3,x); B256 yy=b_add(x3,P_B7);
  uint32_t e[8]={0xbfffff0c,0xffffffff,0xffffffff,0xffffffff,0xffffffff,0xffffffff,0xffffffff,0x3fffffff};
  B256 y=b_setu(1);
  for(int i=7;i>=0;i--) for(int bit=31;bit>=0;bit--){ y=b_sqrmod(y); if((e[i]>>bit)&1) y=b_mulmod(y,yy); }
  // fix y parity to match prefix
  int yodd = (int)(y.w[0]&1u);
  if(yodd != prefix){ // flip to the other root: y' = p - y (p+1-y is off-by-one, off-curve)
    y = b_sub(PRIME, y);
  }
  Jac r; r.X=x;r.Y=y;r.Z=b_setu(1); return r; }
static uint64_t B256_to_FE(B256 b, int i){ return ((uint64_t)b.w[7-2*i]<<32) | b.w[6-2*i]; }
static void FE_to_B256(B256* b, const uint64_t f[4]){ for(int i=0;i<4;i++){ (*b).w[7-2*i]=(uint32_t)(f[i]>>32); (*b).w[6-2*i]=(uint32_t)f[i]; } }
static void le64s_to_B256(B256* b, const uint64_t d[4]){ for(int i=0;i<4;i++){ (*b).w[2*i]=(uint32_t)d[i]; (*b).w[2*i+1]=(uint32_t)(d[i]>>32); } }
static void B256_to_le64s(uint64_t d[4], B256 v){ for(int i=0;i<4;i++) d[i]=((uint64_t)v.w[2*i+1]<<32)|v.w[2*i]; }

#define JMP_CNT 256
#define MD 10
#define STEPS 2048

struct JmpGPU { uint64_t x[4]; uint64_t y[4]; uint64_t d[4]; };

static B256 b_rnd(void){ B256 r; for(int i=0;i<8;i++) r.w[i]=arc4random(); return r; }
static B256 b_rndmax(B256 base){ // rand in [0, base)
  uint32_t o[16]; b_mul(o,b_rnd(),base);
  B256 v; for(int i=0;i<8;i++) v.w[i]=o[i+8];
  return v; // high 256 bits of (rand*base) = (rand*base)>>256 in [0, base)
}

// ---------------- keyhunt hash table (x -> tame dist / up to 2 wild dists) ----------------
typedef struct { B256 x; B256 dt; B256 dw[2]; uint8_t hasT; uint8_t nW; } Slot;
static Slot* HT=NULL; static size_t HTSIZE=0; static size_t HTCOUNT=0;
static unsigned long long g_sameX=0, g_tryRecover=0, g_tw=0, g_ww=0;
static B256 g_QdashX, g_QX, g_x32;

static uint64_t hash256(B256 x){ uint64_t h=x.w[0]^x.w[1]^x.w[2]^x.w[3]^x.w[4]^x.w[5]^x.w[6]^x.w[7];
  h^=h>>33; h*=0xff51afd7ed558ccdULL; h^=h>>33; return h; }

static int check_k(B256 c, B256* out){ // c = k' candidate (k'*G == Qdash). returns 1 if verified
  Jac P=J_MUL(G,c); B256 cx=J_X(P);
  if(b_cmp(cx,g_QdashX)!=0){ return 0; }
  B256 k=b_modn(b_sub(c,g_x32));
  Jac Pk=J_MUL(G,k); B256 kx=J_X(Pk);
  if(b_cmp(kx,g_QX)!=0){ return 0; }
  if(out) *out=k;
  return 1;
}
static int try_tw(B256 dt, B256 dw, B256* out){
  g_tw++;
  B256 rt=b_resid(dt), rw=b_resid(dw);
  B256 cands[4];
  cands[0]=b_submodn(rt,rw);            // t-w
  cands[1]=b_submodn(rw,rt);            // w-t
  cands[2]=b_submodn(b_submodn(ORDER,rt),rw); // -t-w
  cands[3]=b_addmodn(rt,rw);            // t+w
  for(int i=0;i<4;i++) if(check_k(cands[i],out)) return 1;
  return 0;
}
static int try_ww(B256 d1, B256 d2, B256* out){
  g_ww++;
  B256 r1=b_resid(d1), r2=b_resid(d2);
  B256 c1=b_halfmodn(b_submodn(r1,r2));
  B256 c2=b_halfmodn(b_addmodn(r1,r2));
  if(check_k(c1,out)) return 1;
  if(check_k(c2,out)) return 1;
  return 0;
}
static void ht_resize(size_t newsize); // fwd
static int ht_insert(B256 x, B256 d, int type, B256* out); // fwd
static void ht_resize(size_t newsize){
  Slot* old=HT; size_t oldsz=HTSIZE;
  HT=calloc(newsize,sizeof(Slot)); HTSIZE=newsize; HTCOUNT=0;
  for(size_t i=0;i<oldsz;i++){ Slot* s=&old[i];
    if(!s->hasT && s->nW==0) continue;
    if(s->hasT) ht_insert(s->x,s->dt,0,NULL);
    for(int k=0;k<s->nW;k++) ht_insert(s->x,s->dw[k],1,NULL);
  }
  free(old);
}
static int ht_insert(B256 x, B256 d, int type, B256* out){ // type 0=tame, 1=wild
  if(HTCOUNT*10 > HTSIZE*7){ size_t ns=HTSIZE*2; ht_resize(ns); }
  uint64_t hsh=hash256(x);
  for(size_t p=0;p<HTSIZE;p++){
    Slot* s=HT+(size_t)((hsh+p)%HTSIZE);
    if(!s->hasT && s->nW==0){ // empty
      s->x=x;
      if(type==0){ s->hasT=1; s->dt=d; } else { s->nW=1; s->dw[0]=d; }
      HTCOUNT++; return 0;
    }
    if(b_cmp(s->x,x)==0){
      g_sameX++;
      if(type==0){
        if(s->nW){ g_tryRecover++; if(try_tw(d,s->dw[0],out)) return 1; if(s->nW==2 && try_tw(d,s->dw[1],out)) return 1; }
        if(!s->hasT){ s->hasT=1; s->dt=d; }
        return 0;
      } else {
        if(s->hasT){ g_tryRecover++; if(try_tw(s->dt,d,out)) return 1; }
        for(int k=0;k<s->nW;k++){ g_tryRecover++; if(try_ww(s->dw[k],d,out)) return 1; }
        if(s->nW<2){ s->dw[s->nW++]=d; }
        return 0;
      }
    }
  }
  return 0; // full (should not happen after resize threshold)
}

static double now_sec(void){ struct timeval tv; gettimeofday(&tv,NULL); return tv.tv_sec+tv.tv_usec*1e-6; }

int main(int argc, char** argv){
  if(argc<2){ printf("usage: %s config.conf [kangs] [-t seconds] [--selftest]\n", argv[0]); return 1; }
  // --gpu-info: probe the Metal GPU device and exit (used by setup.sh)
  if(strcmp(argv[1],"--gpu-info")==0){
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    if(!dev){ printf("GPU device: NONE (Metal unavailable)\n"); return 2; }
    printf("GPU device: %s\n", [[dev name] UTF8String]);
    // report core-concurrency info (8-core cap enforced at dispatch)
    MTLCompileOptions* copts=[[MTLCompileOptions alloc] init];
    copts.fastMathEnabled=YES;
    NSString* metalSrc=[NSString stringWithContentsOfFile:
      [[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"kangaroo.metal"] encoding:NSUTF8StringEncoding error:nil];
    NSError* err=nil;
    id<MTLLibrary> lib=[dev newLibraryWithSource:metalSrc options:copts error:&err];
    if(lib){
      id<MTLFunction> fWalk=[lib newFunctionWithName:@"kangaroo"];
      id<MTLComputePipelineState> ps=[dev newComputePipelineStateWithFunction:fWalk error:&err];
      if(ps){
        NSUInteger execW=ps.threadExecutionWidth;
        NSUInteger maxTG=ps.maxTotalThreadsPerThreadgroup;
        NSUInteger cores=maxTG/execW;
        printf("GPU cores (reported): %lu (execWidth=%lu, maxTG=%lu)\n",
               (unsigned long)cores,(unsigned long)execW,(unsigned long)maxTG);
        if(cores>8) printf("WARNING: GPU has >8 cores; dispatch will be capped to 8 cores.\n");
      }
    }
    return 0;
  }
  P_B7=b_setu(7);
  P_B7_1=b_add(P_B7,b_setu(1)); // p+1, for flipping y root
  G.X=(B256){0x16f81798,0x59f2815b,0x2dce28d9,0x029bfcdb,0xce870b07,0x55a06295,0xf9dcbbac,0x79be667e};
  G.Y=(B256){0xfb10d4b8,0x9c47d08f,0xa6855419,0xfd17b448,0x0e1108a8,0x5da4fbfc,0x26a3c465,0x483ada77};
  G.Z=b_setu(1);

  NSString* path=[NSString stringWithUTF8String:argv[1]];
  NSString* txt=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if(!txt){ printf("cannot read %s\n", argv[1]); return 1; }
  __block int dpBits=24; __block int Range=0; __block NSString* pubkey=nil;
  double jumpPct=0.1; double startPct=0.0; int useSub=0;
  __block double bJumpPct=jumpPct; __block double bStartPct=startPct; __block int bUseSub=useSub;
  [txt enumerateLinesUsingBlock:^(NSString* line, BOOL* stop){
    if([line hasPrefix:@"PUZZLE="]){ Range=[[line substringFromIndex:7] intValue]; }
    else if([line hasPrefix:@"DP_BITS="]){ dpBits=[[line substringFromIndex:8] intValue]; }
    else if([line hasPrefix:@"PUBKEY="]){ pubkey=[line substringFromIndex:7]; }
    else if([line hasPrefix:@"JUMP_PCT="]){ bJumpPct=[[line substringFromIndex:9] doubleValue]; }
    else if([line hasPrefix:@"START_PCT="]){ bStartPct=[[line substringFromIndex:10] doubleValue]; bUseSub=1; }
  }];
  jumpPct=bJumpPct; startPct=bStartPct; useSub=bUseSub;
  int selftest=0, timeLimit=0; int kangs=65536;
  for(int i=2;i<argc;i++){
    if(strcmp(argv[i],"--selftest")==0) selftest=1;
    else if(strcmp(argv[i],"-t")==0 && i+1<argc) timeLimit=atoi(argv[++i]);
    else if(strcmp(argv[i],"-p")==0 && i+1<argc){ startPct=atof(argv[++i]); useSub=1; }
    else if(argv[i][0]!='-') kangs=atoi(argv[i]);
  }
  if(selftest){ /* use Range/dpBits/kangs from config for isolation testing */ }
  if(Range<=0) Range=32;
  if(Range<10){ printf("range too small\n"); return 1; }

  B256 trueK=b_setu(0);
  Jac Q;
  if(selftest){
    B256 half=b_setu(1); for(int i=0;i<Range-1;i++) half=b_add(half,half);   // 2^(Range-1)
    B256 m1=b_sub(half,b_setu(1));
    B256 magic=b_setu(0x812345ULL);
    B256 lo=magic; for(int i=0;i<8;i++) lo.w[i]&=m1.w[i];
    trueK=b_add(half, lo); // k in [2^(Range-1), 2^Range)
    Q=J_MUL(G,trueK);
    B256 Kx=J_X(Q);
    char hx[80]; sprintf(hx,"%08x%08x%08x%08x%08x%08x%08x%08x",Kx.w[7],Kx.w[6],Kx.w[5],Kx.w[4],Kx.w[3],Kx.w[2],Kx.w[1],Kx.w[0]);
    pubkey=[NSString stringWithUTF8String:hx];
    printf("[selftest] known k=%08x%08x%08x%08x, Q.x=%s, Range=%d bits, DP=%d, kangs=%d\n", trueK.w[7],trueK.w[6],trueK.w[5],trueK.w[4], hx, Range, dpBits, kangs);
  } else {
    Q=decompress_pub([pubkey UTF8String]);
    printf("Range %d bits, DP %d, kangs %d\n", Range, dpBits, kangs);
    B256 qx=J_X(Q); B256 qy=J_Y(Q);
    B256 x3=b_mulmod(b_sqrmod(qx),qx);
    B256 lhs=b_add(x3,P_B7);
    B256 rhs=b_mulmod(qy,qy);
    if(b_cmp(lhs,rhs)!=0) printf("WARN: decompressed Q NOT on curve (y^2 != x^3+7)\n");
    else printf("decompressed Q on curve, y parity=%d\n", (int)(qy.w[0]&1u));
  }
  if(useSub) printf("subrange: START_PCT=%.8f%%  JUMP_PCT=%.6f%%\n", startPct, jumpPct);
  B256 qx=J_X(Q);
  printf("target Q.x = %08x%08x%08x%08x\n", qx.w[7],qx.w[6],qx.w[5],qx.w[4]); fflush(stdout);


  // x32 = 2^(Range-5); Qdash = Q + (x32 + startOff)*G  (random subrange support)
  B256 x32o=b_setu(1); for(int i=0;i<Range-5;i++) x32o=b_add(x32o,x32o);
  B256 rangeHalf=b_setu(1); for(int i=0;i<Range-1;i++) rangeHalf=b_add(rangeHalf,rangeHalf);
  B256 windowW, startOff=b_setu(0);
  if(useSub){
    uint64_t spN=(uint64_t)(startPct*1e8), jpN=(uint64_t)(jumpPct*1e8); uint64_t DEN=10000000000ULL;
    uint32_t _po[16]; b_mul(_po, rangeHalf, b_setu(spN));
    B256 _pB; for(int i=0;i<8;i++) _pB.w[i]=_po[i];
    startOff=b_divu(_pB,DEN);
    uint32_t _wo[16]; b_mul(_wo, rangeHalf, b_setu(jpN));
    B256 _wB; for(int i=0;i<8;i++) _wB.w[i]=_wo[i];
    windowW=b_divu(_wB,DEN);
    B256 tot=b_add(startOff,windowW);
    if(b_cmp(tot,rangeHalf)>0) startOff=b_sub(rangeHalf,windowW);
    if(b_cmp(windowW,x32o)>0) windowW=x32o;
  } else {
    windowW=b_setu(0); for(int i=0;i<34;i++) windowW=b_add(windowW,x32o);
  }
  g_x32=b_add(x32o,startOff);
  B256 tameTop=(b_cmp(x32o,windowW)<0)?x32o:windowW;
  tameTop=b_sub(tameTop,b_setu(1));
  Jac Qdash=J_ADD(Q, J_MUL(G,g_x32));
  g_QX=J_X(Q); g_QdashX=J_X(Qdash);
  Jac PntWild; PntWild.X=J_X(Qdash); PntWild.Y=b_modsub(b_setu(0),J_Y(Qdash)); PntWild.Z=b_setu(1);
  B256 wY=J_Y(PntWild);
  uint64_t pntWildBuf[8]; // x BE u64[4], y BE u64[4]
  { B256 wx=J_X(PntWild); for(int i=0;i<4;i++) pntWildBuf[i]=B256_to_FE(wx,i);
    for(int i=0;i<4;i++) pntWildBuf[4+i]=B256_to_FE(wY,i); }

  // ---- jump tables (3): base = 2^(Range/2+3), 2^(Range-10), 2^(Range-12), even dists ----
  struct JmpGPU jt[3][JMP_CNT];
  { int bases[3]={Range/2+3, Range-10, Range-12};
    for(int t=0;t<3;t++){
      B256 base=b_setu(1); for(int i=0;i<bases[t];i++) base=b_add(base,base);
      for(int i=0;i<JMP_CNT;i++){
        B256 d=b_add(base, b_rndmax(base));
        d.w[0]&=~1u; // must be even
        Jac P=J_MUL(G,d);
        B256 px=J_X(P), py=J_Y(P);
        for(int j=0;j<4;j++){ jt[t][i].x[j]=B256_to_FE(px,j); jt[t][i].y[j]=B256_to_FE(py,j); }
        B256_to_le64s(jt[t][i].d, d);
      }
    }
    B256 dd0; le64s_to_B256(&dd0, jt[0][0].d);
    printf("CPU jt[0][0].d = %08x%08x%08x%08x%08x%08x%08x%08x\n",
      dd0.w[7],dd0.w[6],dd0.w[5],dd0.w[4],dd0.w[3],dd0.w[2],dd0.w[1],dd0.w[0]); fflush(stdout);
  }

  // ---- start distances: tame [1,x32), wild [2,34*x32) even ----
  int tameCut=kangs/3;
  uint64_t* startDist=malloc(kangs*4*sizeof(uint64_t));
  srand(12345);
  { B256 wildRange=windowW;
    B256 x32m1=tameTop;
    for(int i=0;i<kangs;i++){
      B256 d;
      if(i<tameCut){ if(x32m1.w[0]||x32m1.w[1]||x32m1.w[2]||x32m1.w[3]||x32m1.w[4]||x32m1.w[5]||x32m1.w[6]||x32m1.w[7])
          d=b_add(b_setu(1), b_rndmax(x32m1)); else d=b_setu(1); }
      else {
        B256 r=b_rndmax(wildRange); r.w[0]&=~1u;
        if(b_iszero(r)) r=b_setu(2);
        d=r;
      }
      B256_to_le64s(startDist+i*4, d);
    } }

  // ---- Metal setup ----
  id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
  if(!dev){ printf("ERROR: no Metal GPU device available on this Mac.\n"); return 2; }
  printf("GPU device: %s\n", [[dev name] UTF8String]);
  NSString* metalSrc=[NSString stringWithContentsOfFile:
    [[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"kangaroo.metal"] encoding:NSUTF8StringEncoding error:nil];
  NSError* err=nil;
  MTLCompileOptions* copts=[[MTLCompileOptions alloc] init];
  copts.fastMathEnabled=YES;
  id<MTLLibrary> lib=[dev newLibraryWithSource:metalSrc options:copts error:&err];
  if(!lib){ printf("metal lib FAILED: %s\n",[[err localizedDescription] UTF8String]); return 2; }
  id<MTLFunction> fGen=[lib newFunctionWithName:@"kernelGen"];
  id<MTLFunction> fWalk=[lib newFunctionWithName:@"kangaroo"];
  id<MTLComputePipelineState> psGen=[dev newComputePipelineStateWithFunction:fGen error:&err];
  id<MTLComputePipelineState> psWalk=[dev newComputePipelineStateWithFunction:fWalk error:&err];
  if(!psGen||!psWalk){ printf("pipeline FAILED: %s\n",[[err localizedDescription] UTF8String]); return 2; }
  id<MTLCommandQueue> q=[dev newCommandQueue];

  uint64_t maxRec=(uint64_t)((double)kangs*STEPS/((uint64_t)1<<dpBits))*8+262144;
  if(maxRec<65536) maxRec=65536;
  if(maxRec>4*1024*1024) maxRec=4*1024*1024; // cap DP record buffer (4M*72B=288MB)
  uint32_t dpMask=(dpBits>=32)?0xFFFFFFFFu:((1u<<dpBits)-1u);
  uint32_t NK=JMP_CNT, MSt=STEPS, KC=(uint32_t)kangs, TC=(uint32_t)tameCut, MR=(uint32_t)maxRec;
  if((NK&(NK-1))!=0){ printf("JMP_CNT must be a power of 2 (kernel uses bitmask jump index)\n"); return 2; }

  id<MTLBuffer> bJ1=[dev newBufferWithBytes:jt[0] length:sizeof(jt[0]) options:MTLResourceStorageModeShared];
  id<MTLBuffer> bJ2=[dev newBufferWithBytes:jt[1] length:sizeof(jt[1]) options:MTLResourceStorageModeShared];
  id<MTLBuffer> bJ3=[dev newBufferWithBytes:jt[2] length:sizeof(jt[2]) options:MTLResourceStorageModeShared];
  id<MTLBuffer> bStart=[dev newBufferWithBytes:startDist length:kangs*4*sizeof(uint64_t) options:MTLResourceStorageModeShared];
  id<MTLBuffer> bKang=[dev newBufferWithLength:kangs*96 options:MTLResourceStorageModeShared]; // Jac = 3*32 bytes
  id<MTLBuffer> bDist=[dev newBufferWithLength:kangs*32 options:MTLResourceStorageModeShared];
  id<MTLBuffer> bHist=[dev newBufferWithLength:kangs*16*sizeof(uint64_t) options:MTLResourceStorageModeShared];
  id<MTLBuffer> bWild=[dev newBufferWithBytes:pntWildBuf length:64 options:MTLResourceStorageModeShared];
  id<MTLBuffer> bDpCnt=[dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
  id<MTLBuffer> bDpRec=[dev newBufferWithLength:maxRec*72 options:MTLResourceStorageModeShared];

  // --- 8-core GPU cap: query device limits and constrain threadgroup size ---
  NSUInteger execW=[psWalk threadExecutionWidth];
  NSUInteger maxTG=[psWalk maxTotalThreadsPerThreadgroup];
  NSUInteger desiredTG=execW*8; // 8 cores × SIMD width
  NSUInteger tgSize=(desiredTG<=maxTG)?desiredTG:(NSUInteger)maxTG;
  // ensure tgSize is multiple of execW (Metal requirement)
  tgSize=(tgSize/execW)*execW;
  if(tgSize<execW) tgSize=execW;
  // clamp kang count to fit in tgSize-aligned grid
  NSUInteger tgThreads=(NSUInteger)kangs;
  if(tgThreads%(NSUInteger)tgSize!=0) tgThreads=((tgThreads/(NSUInteger)tgSize)+1)*(NSUInteger)tgSize;
  printf("GPU 8-core cap: execWidth=%lu  maxTG=%lu  threadgroup=%lu  kangCount=%lu\n",
         (unsigned long)execW,(unsigned long)maxTG,(unsigned long)tgSize,(unsigned long)tgThreads);
  fflush(stdout);
  MTLSize thg=MTLSizeMake((NSUInteger)tgSize,1,1);
  MTLSize grid=MTLSizeMake((NSUInteger)tgThreads/(NSUInteger)tgSize,1,1);
  KC=(uint32_t)tgThreads; // update KC so kernels see aligned count
  // re-size startDist and kang buffers if kang count changed
  if((uint32_t)tgThreads!=(uint32_t)kangs){
    free(startDist); startDist=malloc(tgThreads*4*sizeof(uint64_t));
    // regenerate start distances for the new count
    srand(12345);
    { B256 wildRange=windowW; B256 x32m1=tameTop;
      for(int i=0;i<(int)tgThreads;i++){
        B256 d;
        if(i<tameCut){ if(x32m1.w[0]||x32m1.w[1]||x32m1.w[2]||x32m1.w[3]||x32m1.w[4]||x32m1.w[5]||x32m1.w[6]||x32m1.w[7])
            d=b_add(b_setu(1), b_rndmax(x32m1)); else d=b_setu(1); }
        else {
          B256 r=b_rndmax(wildRange); r.w[0]&=~1u;
          if(b_iszero(r)) r=b_setu(2);
          d=r;
        }
        B256_to_le64s(startDist+i*4, d);
      } }
    bStart=[dev newBufferWithBytes:startDist length:tgThreads*4*sizeof(uint64_t) options:MTLResourceStorageModeShared];
    bKang=[dev newBufferWithLength:tgThreads*96 options:MTLResourceStorageModeShared];
    bDist=[dev newBufferWithLength:tgThreads*32 options:MTLResourceStorageModeShared];
    bHist=[dev newBufferWithLength:tgThreads*16*sizeof(uint64_t) options:MTLResourceStorageModeShared];
  }

  // kernelGen
  { id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e setComputePipelineState:psGen];
    [e setBuffer:bStart offset:0 atIndex:0]; [e setBuffer:bWild offset:0 atIndex:1];
    [e setBuffer:bKang offset:0 atIndex:2]; [e setBuffer:bDist offset:0 atIndex:3];
    [e setBuffer:bHist offset:0 atIndex:4];
    [e setBytes:&TC length:4 atIndex:5]; [e setBytes:&KC length:4 atIndex:6];
    [e dispatchThreadgroups:grid threadsPerThreadgroup:thg];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
  printf("kernelGen done, starting walk...\n"); fflush(stdout);

  HTSIZE=1<<22; HT=calloc(HTSIZE,sizeof(Slot)); // 4M slots (64MB), supports large kangaroo counts
  uint32_t zero=0;
  double t0=now_sec(); uint64_t totalOps=0; int iter=0, maxIter=selftest?40:0;
  int solved=0; B256 foundK;
  while(!solved && (maxIter==0 || iter<maxIter)){
    if(timeLimit>0 && now_sec()-t0>=timeLimit){
      printf("\n[timeout] %d s reached at iter %d (%.1f Mops/s, HT=%zu, sameX=%llu, rec=%llu tw=%llu ww=%llu)\n", timeLimit, iter, (double)totalOps/(now_sec()-t0)/1e6, HTCOUNT, g_sameX, g_tryRecover, g_tw, g_ww);
      break;
    }
    memcpy([bDpCnt contents],&zero,4);
    id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e setComputePipelineState:psWalk];
    [e setBuffer:bJ1 offset:0 atIndex:0]; [e setBuffer:bJ2 offset:0 atIndex:1]; [e setBuffer:bJ3 offset:0 atIndex:2];
    [e setBuffer:bKang offset:0 atIndex:3]; [e setBuffer:bDist offset:0 atIndex:4]; [e setBuffer:bHist offset:0 atIndex:5];
    [e setBytes:&TC length:4 atIndex:6]; [e setBytes:&dpMask length:4 atIndex:7]; [e setBytes:&MSt length:4 atIndex:8];
    [e setBytes:&NK length:4 atIndex:9]; [e setBytes:&KC length:4 atIndex:10]; [e setBytes:&MR length:4 atIndex:11];
    [e setBuffer:bDpCnt offset:0 atIndex:12]; [e setBuffer:bDpRec offset:0 atIndex:13];
    [e dispatchThreadgroups:grid threadsPerThreadgroup:thg];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];

    uint32_t cnt=*(uint32_t*)[bDpCnt contents];
    if(cnt>maxRec) cnt=maxRec;
    totalOps+=(uint64_t)kangs*STEPS;
    uint64_t* rec=[bDpRec contents];
    for(uint32_t i=0;i<cnt;i++){
      uint64_t* r=rec+(uint64_t)i*9;
      B256 x,d; FE_to_B256(&x,r); le64s_to_B256(&d,r+4);
      int type=((uint64_t)r[8]<(uint64_t)tameCut)?0:1;
      if(ht_insert(x,d,type,&foundK)){ solved=1; break; }
    }
    iter++;
    if(cnt>=maxRec) printf("WARN: DP buffer overflow (maxRec=%llu), increase DP_BITS\n",(unsigned long long)maxRec);
    if(iter%10==0 || (selftest&&iter%1==0)){
      double dt=now_sec()-t0;
      printf("iter %d: DPs=%u/%llu, ops=%.2e (%.1f Mops/s), HT=%zu  \r", iter, cnt,
        (unsigned long long)maxRec, (double)totalOps, totalOps/dt/1e6, HTCOUNT);
      fflush(stdout);
    }
  }
  printf("\n");
  if(solved){
    printf("SOLVED k = %08x%08x%08x%08x%08x%08x%08x%08x\n",
      foundK.w[7],foundK.w[6],foundK.w[5],foundK.w[4],foundK.w[3],foundK.w[2],foundK.w[1],foundK.w[0]);
    if(selftest){
      int ok=b_cmp(foundK,trueK)==0;
      printf("selftest: %s\n", ok?"PASS":"FAIL");
    }
    return 0;
  }
  printf("no collision after %d iters (%.1f s).\n", iter, now_sec()-t0);
  return 1;
}
