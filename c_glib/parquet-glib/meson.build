# -*- indent-tabs-mode: nil -*-
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

project_name = 'parquet-glib'

sources = files(
  'arrow-file-reader.cpp',
  'arrow-file-writer.cpp',
  'metadata.cpp',
  'statistics.cpp',
)

c_headers = files(
  'arrow-file-reader.h',
  'arrow-file-writer.h',
  'metadata.h',
  'statistics.h',
  'parquet-glib.h',
)

cpp_headers = files(
  'arrow-file-reader.hpp',
  'arrow-file-writer.hpp',
  'metadata.hpp',
  'statistics.hpp',
  'parquet-glib.hpp',
)

headers = c_headers + cpp_headers
install_headers(headers, subdir: project_name)


dependencies = [
  arrow,
  parquet,
  arrow_glib,
]
libparquet_glib = library('parquet-glib',
                          sources: sources,
                          install: true,
                          dependencies: dependencies,
                          include_directories: base_include_directories,
                          soversion: so_version,
                          version: library_version)
parquet_glib = declare_dependency(link_with: libparquet_glib,
                                  include_directories: base_include_directories,
                                  dependencies: dependencies)

pkgconfig.generate(libparquet_glib,
                   description: 'C API for Apache Parquet based on GLib',
                   filebase: project_name,
                   name: 'Apache Parquet GLib',
                   requires: ['parquet', 'arrow-glib'],
                   variables: pkgconfig_variables,
                   version: version)

if have_gi
  parquet_glib_gir = \
    gnome.generate_gir(libparquet_glib,
                       dependencies: declare_dependency(sources: arrow_glib_gir),
                       export_packages: 'parquet-glib',
                       extra_args: [
                         '--warn-all',
                         '--include-uninstalled=./arrow-glib/Arrow-1.0.gir',
                       ],
                       header: 'parquet-glib/parquet-glib.h',
                       identifier_prefix: 'GParquet',
                       includes: [
                         'Arrow-1.0',
                       ],
                       install: true,
                       namespace: 'Parquet',
                       nsversion: api_version,
                       sources: sources + c_headers,
                       symbol_prefix: 'gparquet')

  if generate_vapi
    gnome.generate_vapi('parquet-glib',
                        install: true,
                        packages: [
                          arrow_glib_vapi,
                          'gio-2.0',
                        ],
                        sources: [parquet_glib_gir[0]])
  endif
endif
