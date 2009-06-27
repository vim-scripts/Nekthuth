#!/bin/bash

[ -z $NEKTHUTH_DIR ] && NEKTHUTH_DIR=$HOME/.nekthuth/
[ -e $NEKTHUTH_DIR ] || mkdir $NEKTHUTH_DIR
[ -e $NEKTHUTH_DIR/vim ] || mkdir $NEKTHUTH_DIR/vim
[ -e $NEKTHUTH_DIR/lisp ] || mkdir $NEKTHUTH_DIR/lisp

pluginname=${1/.nek/}

lisp() {
  cat > $NEKTHUTH_DIR/lisp/$pluginname.lisp
}

vim() {
  cat > $NEKTHUTH_DIR/vim/$pluginname.vim
}

source $1
