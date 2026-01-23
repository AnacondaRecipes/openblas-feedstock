@echo on
SetLocal EnableDelayedExpansion

mkdir build
cd build

if "%USE_OPENMP%"=="1" (
    REM https://discourse.cmake.org/t/how-to-find-openmp-with-clang-on-macos/8860
    set "CMAKE_EXTRA=-DOpenMP_ROOT=%LIBRARY_LIB%"
    REM not picked up by `find_package(OpenMP)` for some reason
    set "CMAKE_EXTRA=-DOpenMP_Fortran_FLAGS=-fopenmp -DOpenMP_Fortran_LIB_NAMES=libomp"
)

:: millions of lines of warnings with clang-19
set "CFLAGS=%CFLAGS% -w"

cmake -G "Ninja"                            ^
    -DCMAKE_C_COMPILER=clang-cl             ^
    -DCMAKE_Fortran_COMPILER=flang          ^
    -DCMAKE_BUILD_TYPE=Release              ^
    -DCMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% ^
    -DDYNAMIC_ARCH=ON                       ^
    -DBUILD_WITHOUT_LAPACK=no               ^
    -DNO_AVX512=1                           ^
    -DNOFORTRAN=0                           ^
    -DNUM_THREADS=128                       ^
    -DBUILD_SHARED_LIBS=on                  ^
    -DUSE_OPENMP=%USE_OPENMP%               ^
    -DBUILD_PKGCONFIG=ON                    ^
    !CMAKE_EXTRA!                           ^
    %SRC_DIR%
if %ERRORLEVEL% neq 0 exit 1

cmake --build . --target install
if %ERRORLEVEL% neq 0 exit 1

REM Create pkg-config files for standard BLAS/CBLAS/LAPACK names
REM This mirrors what the Unix build does in build.sh lines 171-175
mkdir "%LIBRARY_PREFIX%\lib\pkgconfig" 2>nul
if exist "%LIBRARY_PREFIX%\lib\pkgconfig\openblas.pc" (
    copy "%LIBRARY_PREFIX%\lib\pkgconfig\openblas.pc" "%LIBRARY_PREFIX%\lib\pkgconfig\blas.pc"
    copy "%LIBRARY_PREFIX%\lib\pkgconfig\openblas.pc" "%LIBRARY_PREFIX%\lib\pkgconfig\cblas.pc"  
    copy "%LIBRARY_PREFIX%\lib\pkgconfig\openblas.pc" "%LIBRARY_PREFIX%\lib\pkgconfig\lapack.pc"
)

REM Create site.cfg file for numpy compatibility  
REM This mirrors what the Unix build does in build.sh lines 186-189
copy "%RECIPE_DIR%\site.cfg" "%LIBRARY_PREFIX%\site.cfg"
echo library_dirs = %LIBRARY_PREFIX%\lib >> "%LIBRARY_PREFIX%\site.cfg"
echo include_dirs = %LIBRARY_PREFIX%\include >> "%LIBRARY_PREFIX%\site.cfg"  
echo runtime_include_dirs = %LIBRARY_PREFIX%\lib >> "%LIBRARY_PREFIX%\site.cfg"

ctest -j2
if %ERRORLEVEL% neq 0 exit 1