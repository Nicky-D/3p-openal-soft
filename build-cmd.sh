#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(pwd)"
stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

build=${AUTOBUILD_BUILD_ID:=0}

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/release/lib*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/release/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

pushd "$top/openal-soft"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                archflags=""
            else
                archflags=""
            fi

            # Create staging dirs
            mkdir -p "$stage/include/AL"
            mkdir -p "${stage}/lib/debug"
            mkdir -p "${stage}/lib/release"

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"

                cmake -E env CFLAGS="$archflags /Zi" CXXFLAGS="$archflags /Zi" LDFLAGS="/DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_BUILD_TYPE="Debug" \
                    -DALSOFT_UTILS=OFF -DALSOFT_NO_CONFIG_UTIL=ON -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Debug --clean-first

                cp -a Debug/OpenAL32.{lib,dll,exp,pdb} "$stage/lib/debug/"
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"

                cmake -E env CFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi" CXXFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi /std:c++17 /permissive-" LDFLAGS="/LTCG /OPT:REF /OPT:ICF /DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_BUILD_TYPE="Release" \
                    -DALSOFT_UTILS=OFF -DALSOFT_NO_CONFIG_UTIL=ON -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Release --clean-first
				
                cp -a Release/OpenAL32.{lib,dll,exp,pdb} "$stage/lib/release/"
            popd
            cp include/AL/*.h $stage/include/AL/

            # Must be done after the build.  version.h is created as part of the build.
            version="$(sed -n -E 's/#define ALSOFT_VERSION "([^"]+)"/\1/p' "build_release/version.h" | tr -d '\r' )"
            echo "${version}" > "${stage}/VERSION.txt"
        ;;

        darwin*)
        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            # unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"

            # Setup build flags
			DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
			RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
			DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Create staging dirs
            mkdir -p "$stage/include/AL"
            mkdir -p "${stage}/lib/debug"
            mkdir -p "${stage}/lib/release"

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"
                cmake -E env CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" \
                cmake .. -DCMAKE_BUILD_TYPE="Debug" \
                    -DALSOFT_UTILS=OFF -DALSOFT_NO_CONFIG_UTIL=ON -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
                    -DCMAKE_INSTALL_PREFIX="$stage"

                cmake --build . -j$JOBS --config Debug --clean-first

                cp -a libopenal.so* "$stage/lib/debug/"
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"
                cmake -E env CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" \
                cmake .. -DCMAKE_BUILD_TYPE="Release" \
                    -DALSOFT_UTILS=OFF -DALSOFT_NO_CONFIG_UTIL=ON -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
                    -DCMAKE_INSTALL_PREFIX="$stage"

                cmake --build . -j$JOBS --config Release --clean-first
				
                cp -a libopenal.so* "$stage/lib/release/"
            popd
            cp include/AL/*.h $stage/include/AL/

            # Must be done after the build.  version.h is created as part of the build.
            version="$(sed -n -E 's/#define ALSOFT_VERSION "([^"]+)"/\1/p' "build_release/version.h" | tr -d '\r' )"
            echo "${version}" > "${stage}/VERSION.txt"
        ;;
    esac
popd


pushd "$top/freealut"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                archflags=""
            else
                archflags=""
            fi

            # Create staging dirs
            mkdir -p "$stage/include/AL"
            mkdir -p "${stage}/lib/debug"
            mkdir -p "${stage}/lib/release"

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"

                cmake -E env CFLAGS="$archflags /Zi" CXXFLAGS="$archflags /Zi" LDFLAGS="/DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_BUILD_TYPE="Debug" \
                    -DOPENAL_LIB_DIR="$(cygpath -m "$stage/lib/debug")" -DOPENAL_INCLUDE_DIR="$(cygpath -m "$stage/include")" \
                    -DBUILD_STATIC=OFF -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Debug --clean-first

                cp -a Debug/alut.{lib,dll,exp,pdb} "$stage/lib/debug/"
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"

                cmake -E env CFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi" CXXFLAGS="$archflags /O2 /Ob3 /GL /Gy /Zi /std:c++17 /permissive-" LDFLAGS="/LTCG /OPT:REF /OPT:ICF /DEBUG:FULL" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_BUILD_TYPE="Release" \
                    -DOPENAL_LIB_DIR="$(cygpath -m "$stage/lib/release")" -DOPENAL_INCLUDE_DIR="$(cygpath -m "$stage/include")" \
                    -DBUILD_STATIC=OFF -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

                cmake --build . --config Release --clean-first
				
                cp -a Release/alut.{lib,dll,exp,pdb} "$stage/lib/release/"
            popd
            cp include/AL/*.h $stage/include/AL/
        ;;

        darwin*)
        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            # unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"

            # Setup build flags
			DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
			RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
			DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Create staging dirs
            mkdir -p "$stage/include/AL"
            mkdir -p "${stage}/lib/debug"
            mkdir -p "${stage}/lib/release"

            # Debug Build
            mkdir -p "build_debug"
            pushd "build_debug"
                cmake -E env CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" \
                cmake .. -DCMAKE_BUILD_TYPE="Debug" \
                    -DOPENAL_LIB_DIR="$stage/lib/debug" -DOPENAL_INCLUDE_DIR="$stage/include" \
                    -DBUILD_STATIC=OFF -DCMAKE_INSTALL_PREFIX="$stage"

                cmake --build . -j$JOBS --config Debug --clean-first

                cp -a libalut.so* "$stage/lib/debug/"
            popd

            # Release Build
            mkdir -p "build_release"
            pushd "build_release"
                cmake -E env CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" \
                cmake .. -DCMAKE_BUILD_TYPE="Release" \
                    -DOPENAL_LIB_DIR="$stage/lib/release" -DOPENAL_INCLUDE_DIR="$stage/include" \
                    -DBUILD_STATIC=OFF -DCMAKE_INSTALL_PREFIX="$stage"

                cmake --build . -j$JOBS --config Release --clean-first
				
                cp -a libalut.so* "$stage/lib/release/"
            popd
            cp include/AL/*.h $stage/include/AL/
        ;;
    esac
popd

mkdir -p "$stage/LICENSES"
cp "$top/openal-soft/COPYING" "$stage/LICENSES/openal-soft.txt"
cp "$top/freealut/COPYING" "$stage/LICENSES/freealut.txt"
