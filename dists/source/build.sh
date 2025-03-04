#!/bin/bash

# Simple script to prepare for release

version="1.4-snapshot20111026";
build_d="../release";

if test -d $build_d/ledgersmb; then
  rm -rf $build_d/ledgersmb
fi
rm -rf $build_d/ledgersmb
svn export . $build_d/ledgersmb

cd $build_d
tar -zcvf ledgersmb-$version.tar.gz ledgersmb
