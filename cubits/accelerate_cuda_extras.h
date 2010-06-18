/* -----------------------------------------------------------------------------
 *
 * Module    : Extras
 * Copyright : (c) [2009..2010] Trevor L. McDonell
 * License   : BSD
 *
 * ---------------------------------------------------------------------------*/

#ifndef __ACCELERATE_CUDA_EXTRAS_H__
#define __ACCELERATE_CUDA_EXTRAS_H__

#include <math.h>
#include <stdio.h>
#include <stdint.h>

#include <cuda_runtime.h>

/* -----------------------------------------------------------------------------
 * Textures
 * -----------------------------------------------------------------------------
 *
 * CUDA texture definitions and access functions are defined in terms of
 * templates, and hence only available through the C++ interface. Expose some
 * dummy wrappers to enable parsing with language-c.
 *
 * FIXME: We need extra code generation support for 64-bit types
 */
#ifdef __cplusplus

typedef texture<uint32_t, 1> TexWord;
typedef texture<uint32_t, 2> TexWord64;
typedef texture<uint32_t, 1> TexWord32;
typedef texture<uint16_t, 1> TexWord16;
typedef texture<uint8_t,  1> TexWord8;

typedef texture<int32_t, 1> TexInt;
typedef texture<int32_t, 2> TexInt64;
typedef texture<int32_t, 1> TexInt32;
typedef texture<int16_t, 1> TexInt16;
typedef texture<int8_t,  1> TexInt8;

typedef texture<float, 1> TexFloat;
typedef texture<int2,  1> TexDouble;

#else

typedef void* TexWord;
typedef void* TexWord32;
typedef void* TexWord16;
typedef void* TexWord8;

typedef void* TexInt;
typedef void* TexInt32;
typedef void* TexInt16;
typedef void* TexInt8;

typedef void* TexFloat;
typedef void* TexDouble;

void* tex1Dfetch(const void*, const int);
void* tex1D(const void*, const float);
void* tex2D(const void*, const float, const float);
void* tex3D(const void*, const float, const float, const float);

#endif

/* -----------------------------------------------------------------------------
 * Indices
 * -------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
 * Tuple Types
 * -------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
 * Utilities
 * -------------------------------------------------------------------------- */

/*
 * Core assert function. Don't let this escape...
 */
#if defined(__CUDACC__) || !defined(__DEVICE_EMULATION__)
#define __assert(e, file, line) ((void)0)
#else
#define __assert(e, file, line) \
    ((void) fprintf (stderr, "%s:%u: failed assertion `%s'\n", file, line, e), abort())
#endif

/*
 * Test the given expression, and abort the program if it evaluates to false.
 * Only available in debug mode.
 */
#ifndef _DEBUG
#define assert(e)               ((void)0)
#else
#define assert(e)  \
    ((void) ((e) ? (void(0)) : __assert (#e, __FILE__, __LINE__)))
#endif

/*
 * Macro to insert __syncthreads() in device emulation mode
 */
#ifdef __DEVICE_EMULATION__
#define __EMUSYNC               __syncthreads()
#else
#define __EMUSYNC
#endif

/*
 * Check the return status of CUDA API calls, and abort with an appropriate
 * error string on failure.
 */
#define CUDA_SAFE_CALL_NO_SYNC(call)                                           \
    do {                                                                       \
        cudaError err = call;                                                  \
        if(cudaSuccess != err) {                                               \
            const char *str = cudaGetErrorString(err);                         \
            __assert(str, __FILE__, __LINE__);                                 \
        }                                                                      \
    } while (0)

#define CUDA_SAFE_CALL(call)                                                   \
    do {                                                                       \
        CUDA_SAFE_CALL_NO_SYNC(call);                                          \
        CUDA_SAFE_CALL_NO_SYNC(cudaThreadSynchronize());                       \
    } while (0)


#ifdef __cplusplus
extern "C" {
#endif

/*
 * Determine if the input is a power of two
 */
inline int
isPow2(unsigned int x)
{
    return ((x&(x-1)) == 0);
}

/*
 * Compute the next highest power of two
 */
inline unsigned int
ceilPow2(unsigned int x)
{
#if 0
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return ++x;
#endif

    return (isPow2(x)) ? x : 1u << (int) ceil(log2((double)x));
}

/*
 * Compute the next lowest power of two
 */
inline unsigned int
floorPow2(unsigned int x)
{
#if 0
    float nf = (float) n;
    return 1 << (((*(int*)&nf) >> 23) - 127);
#endif

    int exp;
    frexp(x, &exp);
    return 1 << (exp - 1);
}

/*
 * computes next highest multiple of f from x
 */
inline unsigned int
multiple(unsigned int x, unsigned int f)
{
    return ((x + (f-1)) / f);
}

/*
 * MS Excel-style CEIL() function. Rounds x up to nearest multiple of f
 */
inline unsigned int
ceiling(unsigned int x, unsigned int f)
{
    return multiple(x, f) * f;
}

#undef __assert
#ifdef __cplusplus
}
#endif
#endif  // __ACCELERATE_CUDA_EXTRAS_H__

// vim: filetype=cuda.c
