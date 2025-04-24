@echo on
SetLocal EnableDelayedExpansion

mkdir build
cd build

if "%USE_OPENMP%"=="1" (
    set "CMAKE_EXTRA=^
    -DOpenMP_ROOT=%LIBRARY_LIB% ^
    -DOpenMP_Fortran_FLAGS=/Qopenmp ^
    -DOpenMP_Fortran_LIB_NAMES=libiomp5md ^
    -DOpenMP_Fortran_LIBRARIES=%LIBRARY_LIB%\libiomp5md.lib"
)

:: millions of lines of warnings with clang-19
set "CFLAGS=%CFLAGS% -w"

:: Adhere to IEEE standard for floating-point arithmetic
set "CFLAGS=%CFLAGS% /fp:strict"
set "FFLAGS=%FFLAGS% /fp:strict"

cmake -G "Ninja"                            ^
    -DCMAKE_C_COMPILER=icx                  ^
    -DCMAKE_Fortran_COMPILER=ifx            ^
    -DCMAKE_BUILD_TYPE=Release              ^
    -DCMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% ^
    -DDYNAMIC_ARCH=ON                       ^
    -DBUILD_WITHOUT_LAPACK=no               ^
    -DNO_AVX512=1                           ^
    -DNOFORTRAN=0                           ^
    -DNUM_THREADS=128                       ^
    -DBUILD_SHARED_LIBS=on                  ^
    -DUSE_OPENMP=%USE_OPENMP%               ^
    !CMAKE_EXTRA!                           ^
    %SRC_DIR%
if %ERRORLEVEL% neq 0 exit 1

cmake --build . --target install
if %ERRORLEVEL% neq 0 exit 1

ctest -j2
if %ERRORLEVEL% neq 0 exit 1
