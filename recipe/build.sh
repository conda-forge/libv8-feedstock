#!/bin/bash
set -euo pipefail
set -x

export LD_LIBRARY_PATH=$PREFIX/lib
sed -ie 's/v8_enable_snapshot_compression = true/v8_enable_snapshot_compression = false/g' BUILD.gn

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
  sed -ie "s;@PREFIX@;${PREFIX};g" build/config/mac/BUILD.gn
  echo "mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\"" >> build/config/gclient_args.gni
fi

if [[ "${target_platform}" == "osx-64" ]]; then
  echo 'mac_sdk_min="10.9"' >> build/config/gclient_args.gni
  gn gen out.gn "--args=use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"10.9\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Explicitly link to libz, otherwise _compressBound cannot be found
  sed -ie "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  sed -ie "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja

elif [[ "${target_platform}" == "osx-arm64" ]]; then
  echo 'mac_sdk_min="11.0"' >> build/config/gclient_args.gni
  gn gen out.gn "--args=target_cpu=\"arm64\" use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"11.0\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Manually override the compiler
  sed -ie "s;bin/clang;bin/${CC};g" out.gn/toolchain.ninja

  # Explicitly link to libz, otherwise _compressBound cannot be found
  sed -ie "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  sed -ie "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja
elif [[ "${target_platform}" =~ linux.* ]]; then
  echo 'use_sysroot=false' >> build/config/gclient_args.gni
  echo 'is_clang=false' >> build/config/gclient_args.gni
  echo 'treat_warnings_as_errors=false' >> build/config/gclient_args.gni
  echo 'fatal_linker_warnings=false'  >> build/config/gclient_args.gni

  gn gen out.gn "--args=use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" is_component_build=true icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" use_sysroot=false is_clang=false treat_warnings_as_errors=false fatal_linker_warnings=false enable_stripping=true"
  sed -i "s/ gcc/ ${HOST}-gcc/g" out.gn/toolchain.ninja
  sed -i "s/ g++/ ${HOST}-g++/g" out.gn/toolchain.ninja
  sed -i 's/deps = x86_64-conda-linux-gnu.*$//g' out.gn/toolchain.ninja
  sed -i 's/-Werror//g' out.gn/**/*.ninja

  # ld.gold segfaults on mksnapshot linkage with binutils 2.35
  # for f in "out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/v8.ninja out.gn/obj/v8_libbase.ninja out.gn/obj/v8_for_testing.ninja out.gn/obj/mksnapshot.ninja out.gn/obj/v8_simple_parser_fuzzer.ninja out.gn/obj/v8_simple_wasm_async_fuzzer.ninja out.gn/obj/v8_simple_wasm_fuzzer.ninja out.gn/obj/third_party/zlib/zlib.ninja out.gn/obj/cppgc_standalone.ninja"; do
  for f in "$(ls out.gn/obj/*.ninja) out.gn/obj/third_party/zlib/zlib.ninja"; do
    sed -i 's/--threads//g' $f
    sed -i 's/-fuse-ld=gold//g' $f
    sed -i 's/--thread-count=4//g' $f
    if [[ "$f" != "out.gn/obj/v8_libbase.ninja" ]]; then
      if [[ "$f" != "out.gn/obj/third_party/zlib/zlib.ninja" ]]; then
        sed -ie "s/libs =/libs = -lz/g" $f
      fi
    fi
  done
  for f in "out.gn/obj/mksnapshot.ninja out.gn/obj/v8.ninja out.gn/obj/wee8.ninja out.gn/obj/d8.ninja"; do
    sed -ie "s/libs = -latomic/libs = -lz -latomic/g" $f
  done
fi

ninja -C out.gn v8

mkdir -p $PREFIX/lib
cp out.gn/libv8*${SHLIB_EXT} $PREFIX/lib
cp out.gn/libchrome_zlib${SHLIB_EXT} $PREFIX/lib
mkdir -p $PREFIX/include
cp -r include/* $PREFIX/include/
