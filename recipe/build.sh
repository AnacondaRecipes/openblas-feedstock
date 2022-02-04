#!/bin/bash

set -e -u

if [[ ${target_platform} != linux-aarch64 ]] && [[ ${target_platform} != linux-64 ]]; then
    # Stuart's recommendation to stop lapack-test from failing
    # on linux-64 docker image this operation is not permitted
    ulimit -s 50000
fi

# Fix segfault issue arising from a bug in Linux 2.6.32; we can probably skip
# this patch once we drop support for CentOS/RHEL 6.x. For details, see:
# https://github.com/xianyi/OpenBLAS/wiki/faq#Linux_SEGFAULT
patch < segfaults.patch

# Build configuration options
declare -a build_opts

# Fix ctest not automatically discovering tests
LDFLAGS=$(echo "${LDFLAGS}" | sed "s/-Wl,--gc-sections//g")

# See this workaround
# ( https://github.com/xianyi/OpenBLAS/issues/818#issuecomment-207365134 ).
export CF="${CFLAGS} -Wno-unused-parameter -Wno-old-style-declaration"
unset CFLAGS

# Silly "if" statement, but it makes things clearer
if [[ ${target_platform} == osx-* ]]; then
    # No OpenMP on Mac.  We mix gfortran and clang for the macOS build, and we
    # want to avoid mixing their OpenMP implementations until we've done more
    # extensive testing.
    USE_OPENMP="0"

    export CF="$CF -Wl,-rpath,$PREFIX/lib"
    export LAPACK_FFLAGS="${LAPACK_FFLAGS:-} -Wl,-rpath,$PREFIX/lib"
    export FFLAGS="$FFLAGS -Wl,-rpath,$PREFIX/lib -isysroot ${CONDA_BUILD_SYSROOT}"
elif [[ ${target_platform} == linux-* ]]; then
    # GNU OpenMP is not fork-safe.  We disable OpenMP for now, so that
    # downstream packages don't hang as a result.  Conda-forge builds OpenBLAS
    # for Linux using gfortran but uses the LLVM OpenMP implementation at
    # run-time; however, we want to avoid such mixing in the defaults channel
    # until more extensive has been done.
    USE_OPENMP="0"
fi

if [[ "$USE_OPENMP" == "1" ]]; then
    # Run the fork test (as part of `openblas_utest`)
    sed -i.bak 's/test_potrs.o/test_potrs.o test_fork.o/g' utest/Makefile
fi
build_opts+=(USE_OPENMP=${USE_OPENMP})

if [ ! -z "$FFLAGS" ]; then
    # Don't use GNU OpenMP, which is not fork-safe
    export FFLAGS="${FFLAGS/-fopenmp/ }"

    export FFLAGS="${FFLAGS} -frecursive"

    export LAPACK_FFLAGS="${FFLAGS}"
fi

# Because -Wno-missing-include-dirs does not work with gfortran:
[[ -d "${PREFIX}"/include ]] || mkdir "${PREFIX}"/include
[[ -d "${PREFIX}"/lib ]] || mkdir "${PREFIX}"/lib

# All our target platforms are 64-bit and support dynamic dispatch.
build_opts+=(BINARY="64")
build_opts+=(DYNAMIC_ARCH=1)

# Set target platform-/CPU-specific options
case "${target_platform}" in
    linux-aarch64)
        build_opts+=(TARGET="ARMV8")
        ;;
    linux-ppc64le)
        build_opts+=(TARGET="POWER8")
        ;;
    linux-s390x)
        build_opts+=(TARGET="Z14")
        ;;
    linux-64)
        # Oldest x86/x64 target microarch that has 64-bit extensions
        build_opts+=(TARGET="PRESCOTT")
        ;;
    osx-64)
        # Oldest OS X version we support is Mavericks (10.9), which requires a
        # system with at least an Intel Core 2 CPU.
        build_opts+=(TARGET="CORE2")
        ;;
    osx-arm64)
        build_opts+=(TARGET="VORTEX")
        ;;
esac

# Placeholder for future builds that may include ILP64 variants.
build_opts+=(INTERFACE64=0)
build_opts+=(SYMBOLSUFFIX="")

# Build LAPACK.
build_opts+=(NO_LAPACK=0)

# Enable threading. This can be controlled to a certain number by
# setting OPENBLAS_NUM_THREADS before loading the library.
build_opts+=(USE_THREAD=1)
build_opts+=(NUM_THREADS=128)

# Disable CPU/memory affinity handling to avoid problems with NumPy and R
build_opts+=(NO_AFFINITY=1)

# Fix buggy AVX-512 intrinsics header in older GCC releases; references:
#   * https://gcc.gnu.org/bugzilla/show_bug.cgi?id=87517
#   * https://gcc.gnu.org/legacy-ml/gcc-patches/2018-01/msg01962.html
# TODO: Remove this once we update the defaults linux-64 compilers.
if [[ ${target_platform} == "linux-64" && `$CC -dumpversion` == 7.3.* ]]; then
    pushd "`$CC -print-search-dirs | grep '^install: ' | cut -c10-`"
    patch -p0 <<'EOF'
--- include/avx512fintrin.h
+++ include/avx512fintrin.h
@@ -3333,7 +3333,7 @@
     (__m512d)__builtin_ia32_vfmaddsubpd512_mask(A, B, C, -1, R)
 
 #define _mm512_mask_fmaddsub_round_pd(A, U, B, C, R)    \
-    (__m512d)__builtin_ia32_vfmaddpd512_mask(A, B, C, U, R)
+    (__m512d)__builtin_ia32_vfmaddsubpd512_mask(A, B, C, U, R)
 
 #define _mm512_mask3_fmaddsub_round_pd(A, B, C, U, R)   \
     (__m512d)__builtin_ia32_vfmaddsubpd512_mask3(A, B, C, U, R)
@@ -7298,7 +7298,7 @@
 
 extern __inline __m512d
 __attribute__ ((__gnu_inline__, __always_inline__, __artificial__))
-_mm512_abs_pd (__m512 __A)
+_mm512_abs_pd (__m512d __A)
 {
   return (__m512d) _mm512_and_epi64 ((__m512i) __A,
 				     _mm512_set1_epi64 (0x7fffffffffffffffLL));
@@ -7306,7 +7306,7 @@
 
 extern __inline __m512d
 __attribute__ ((__gnu_inline__, __always_inline__, __artificial__))
-_mm512_mask_abs_pd (__m512d __W, __mmask8 __U, __m512 __A)
+_mm512_mask_abs_pd (__m512d __W, __mmask8 __U, __m512d __A)
 {
   return (__m512d)
 	 _mm512_mask_and_epi64 ((__m512i) __W, __U, (__m512i) __A,
EOF
    popd
fi

# USE_SIMPLE_THREADED_LEVEL3 is necessary to avoid hangs when more than one process uses blas:
#    https://github.com/xianyi/OpenBLAS/issues/1456
#    https://github.com/xianyi/OpenBLAS/issues/294
#    https://github.com/scikit-learn/scikit-learn/issues/636
#USE_SIMPLE_THREADED_LEVEL3=1

make ${build_opts[@]} \
     HOST=${HOST} CROSS_SUFFIX="${HOST}-" \
     CFLAGS="${CF}" FFLAGS="${FFLAGS}"

# BLAS tests are now run as part of build process; LAPACK tests still need to
# be separately built and run.
#OPENBLAS_NUM_THREADS=${CPU_COUNT} CFLAGS="${CF}" FFLAGS="${FFLAGS}" make test
OPENBLAS_NUM_THREADS=${CPU_COUNT} CFLAGS="${CF}" FFLAGS="${FFLAGS}" \
    make lapack-test ${build_opts[@]}

CFLAGS="${CF}" FFLAGS="${FFLAGS}" \
    make install PREFIX="${PREFIX}" ${build_opts[@]}

# As OpenBLAS, now will have all symbols that BLAS, CBLAS or LAPACK have,
# create libraries with the standard names that are linked back to
# OpenBLAS. This will make it easier for packages that are looking for them.
for arg in blas cblas lapack; do
  ln -fs "${PREFIX}"/lib/pkgconfig/openblas.pc "${PREFIX}"/lib/pkgconfig/$arg.pc
  ln -fs "${PREFIX}"/lib/libopenblas.a "${PREFIX}"/lib/lib$arg.a
  ln -fs "${PREFIX}"/lib/libopenblas$SHLIB_EXT "${PREFIX}"/lib/lib$arg$SHLIB_EXT
done

if [[ ${target_platform} == osx-* ]]; then
  # Needs to fix the install name of the dylib so that the downstream projects will link
  # to libopenblas.dylib instead of libopenblasp-r0.2.20.dylib
  # In linux, SONAME is libopenblas.so.0 instead of libopenblasp-r0.2.20.so, so no change needed
  test -f ${PREFIX}/lib/libopenblas.0.dylib || \
      ln -s ${PREFIX}/lib/libopenblas.dylib ${PREFIX}/lib/libopenblas.0.dylib
  ${INSTALL_NAME_TOOL} -id "${PREFIX}"/lib/libopenblas.0.dylib "${PREFIX}"/lib/libopenblas.dylib
fi

cp "${RECIPE_DIR}"/site.cfg "${PREFIX}"/site.cfg
echo library_dirs = ${PREFIX}/lib >> "${PREFIX}"/site.cfg
echo include_dirs = ${PREFIX}/include >> "${PREFIX}"/site.cfg
echo runtime_include_dirs = ${PREFIX}/lib >> "${PREFIX}"/site.cfg
