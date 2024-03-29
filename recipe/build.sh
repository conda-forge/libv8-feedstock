#!/bin/bash
set -euo pipefail
set -x

export LD_LIBRARY_PATH=$PREFIX/lib
sed -i 's/v8_enable_snapshot_compression = true/v8_enable_snapshot_compression = false/g' BUILD.gn

cat <<EOF >build/config/gclient_args.gni
use_custom_libcxx=false
clang_use_chrome_plugins=false
v8_use_external_startup_data=false
is_debug=false
clang_base_path="${BUILD_PREFIX}"
is_component_build=true
icu_use_system=true
icu_include_dir="$PREFIX/include"
icu_lib_dir="$PREFIX/lib"
v8_use_snapshot=false
enable_stripping=true
checkout_google_benchmark=false
EOF

if [[ "${target_platform}" =~ osx.* ]]; then
  sed -i "s;@PREFIX@;${PREFIX};g" build/config/mac/BUILD.gn
  echo "mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\"" >> build/config/gclient_args.gni
fi

if [[ "${target_platform}" == "osx-64" ]]; then
  echo 'mac_sdk_min="10.9"' >> build/config/gclient_args.gni
  gn gen out.gn "--args=use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"10.9\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Explicitly link to libz, otherwise _compressBound cannot be found
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja

elif [[ "${target_platform}" == "osx-arm64" ]]; then
  echo 'mac_sdk_min="11.0"' >> build/config/gclient_args.gni
  gn gen out.gn "--args=target_cpu=\"arm64\" use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"11.0\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Manually override the compiler
  sed -i "s;bin/clang;bin/${CC};g" out.gn/toolchain.ninja

  # Explicitly link to libz, otherwise _compressBound cannot be found
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja
elif [[ "${target_platform}" == linux-* ]]; then
  echo 'use_sysroot=false' >> build/config/gclient_args.gni
  echo 'is_clang=false' >> build/config/gclient_args.gni
  echo 'treat_warnings_as_errors=false' >> build/config/gclient_args.gni
  echo 'fatal_linker_warnings=false'  >> build/config/gclient_args.gni

  if [[ "${target_platform}" == "linux-aarch64" ]]; then
    TARGET_CPU='target_cpu="arm64" v8_target_cpu="arm64"'
  elif [[ "${target_platform}" == "linux-ppc64le" ]]; then
    TARGET_CPU='target_cpu="ppc64" v8_target_cpu="ppc64" host_byteorder="little"'
  fi

  gn gen out.gn "--args=target_os=\"linux\" ${TARGET_CPU:-} use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" is_component_build=true icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" use_sysroot=false is_clang=false treat_warnings_as_errors=false fatal_linker_warnings=false enable_stripping=true"
  sed -i "s/ gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
  sed -i "s/ g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
  sed -i "s/ ${HOST}-gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
  sed -i "s/ ${HOST}-g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
  sed -i "s/deps = $(basename ${CC})\$//g" out.gn/toolchain.ninja
  sed -i "s/deps = $(basename ${CXX})\$//g" out.gn/toolchain.ninja

  if [[ "${target_platform}" == "linux-aarch64" ]]; then
    sed -i "s/ aarch64-linux-gnu-gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
    sed -i "s/ aarch64-linux-gnu-g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-readelf/$(basename ${READELF})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-nm/$(basename ${NM})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-ar/$(basename ${AR})/g" out.gn/toolchain.ninja
  fi

  # ld.gold segfaults on mksnapshot linkage with binutils 2.35
  # for f in out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/v8.ninja out.gn/obj/v8_libbase.ninja out.gn/obj/v8_for_testing.ninja out.gn/obj/mksnapshot.ninja out.gn/obj/v8_simple_parser_fuzzer.ninja out.gn/obj/v8_simple_wasm_async_fuzzer.ninja out.gn/obj/v8_simple_wasm_fuzzer.ninja out.gn/obj/third_party/zlib/zlib.ninja out.gn/obj/cppgc_standalone.ninja; do
  for f in out.gn/obj/*.ninja out.gn/obj/third_party/zlib/zlib.ninja; do
    sed -i 's/--threads//g' $f
    sed -i 's/-fuse-ld=gold//g' $f
    sed -i 's/--thread-count=4//g' $f
  done
  for f in out.gn/obj/mksnapshot.ninja out.gn/obj/v8.ninja out.gn/obj/wee8.ninja out.gn/obj/d8.ninja; do
    if [ -f "$f" ]; then
      sed -i "s/libs = -latomic/libs = -lz -latomic/g" $f
    fi
  done

  # [[nodiscard]] support in GCC 9 is not as good as in clang
  sed -i "s/# define V8_HAS_CPP_ATTRIBUTE_NODISCARD (V8_HAS_CPP_ATTRIBUTE(nodiscard))//g" include/v8config.h
fi

find out.gn -type f -name '*.ninja' -exec sed -i 's|-Werror||g' {} +

ninja -C out.gn v8

mkdir -p $PREFIX/lib
cp out.gn/libv8*${SHLIB_EXT} $PREFIX/lib
cp out.gn/libchrome_zlib${SHLIB_EXT} $PREFIX/lib
mkdir -p $PREFIX/include
cp -r include/* $PREFIX/include/
