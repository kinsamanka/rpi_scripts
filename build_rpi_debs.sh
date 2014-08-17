#!/bin/sh

DIST=wheezy
NUM_CORES=4

LINKS='
http://deb.dovetail-automata.com/pool/main/libs/libsodium/
http://deb.dovetail-automata.com/pool/main/z/zeromq4/
http://deb.dovetail-automata.com/pool/main/c/czmq/
http://deb.dovetail-automata.com/pool/main/j/jansson/
http://deb.dovetail-automata.com/pool/main/libw/libwebsockets/
http://deb.dovetail-automata.com/pool/main/p/pyzmq/
http://deb.dovetail-automata.com/pool/main/x/xenomai/
'
#http://deb.dovetail-automata.com/pool/main/m/machinekit/

CYTHON_LINK='http://cdn.debian.net/debian/pool/main/c/cython/cython_0.19.1+git34-gac3e3a2-1~bpo70+1.dsc'

MIRROR='http://mirrordirector.raspbian.org/raspbian/'

DSCDIR="`pwd`/src_files"

BUILDPLACE="`pwd`/build"
BASEPATHROOT="`pwd`/raspbian"
BASEPATH="${BASEPATHROOT}/base.cow"
BUILDRESULT="`pwd`/result"
HOOKDIR="`pwd`/hooks"
APTCACHE="`pwd`/aptcache"
CCACHEDIR="`pwd`/ccache"

BINDMOUNTS="${BUILDRESULT}"
EXTRAPACKAGES="apt-utils"
DEBBUILDOPTS="-I -i -j${NUM_CORES}"
OTHERMIRROR="deb [trusted=yes] file://${BUILDRESULT} ./"

COWBUILDER_OPTIONS="\
  BUILDPLACE=${BUILDPLACE} BASEPATH=${BASEPATH} BUILDRESULT=${BUILDRESULT}\
  HOOKDIR=${HOOKDIR} APTCACHE=${APTCACHE} CCACHEDIR=${CCACHEDIR}\
  BINDMOUNTS=${BINDMOUNTS} EXTRAPACKAGES=${EXTRAPACKAGES}\
  "

install_cowbuilder() {
  # check if running on arm
  if echo `uname -m` | egrep -q "arm" ; then
    PACKAGES=
  else
    PACKAGES='qemu-user-static binfmt-support'
  fi

  # install required packages
  apt-get install cowbuilder devscripts ${PACKAGES}
}

setup_cowbuilder() {
  # check if running on arm
  if echo `uname -m` | egrep -q "arm" ; then
    EXTRAS=
  else
    EXTRAS='--architecture armhf --debootstrap qemu-debootstrap --debootstrapopts --variant=buildd'
  fi

  # install raspbian keyring
  wget http://www.mirrorservice.org/sites/archive.raspbian.org/raspbian/pool/main/r/raspbian-archive-keyring/raspbian-archive-keyring_20120528.2_all.deb 
  dpkg -i raspbian-archive-keyring_20120528.2_all.deb
  rm raspbian-archive-keyring_20120528.2_all.deb

  mkdir -p ${BUILDPLACE}
  mkdir -p ${BASEPATHROOT}
  mkdir -p ${BUILDRESULT}
  mkdir -p ${HOOKDIR}
  mkdir -p ${APTCACHE}
  mkdir -p ${CCACHEDIR}
  mkdir -p ${DSCDIR}

  # create pbuilderrc
  a=`pwd`/.pbuilderrc
  cat <<EOF > ${a}
APTCACHE=${APTCACHE}
APTCACHEHARDLINK="yes"
EOF

  # create hooks
  cat <<EOF > ${HOOKDIR}/D05Deps
(cd ${BUILDRESULT}; apt-ftparchive packages . > Packages)
apt-get update
EOF
  chmod +x ${HOOKDIR}/D05Deps

  env ${COWBUILDER_OPTIONS} HOME=`pwd` cowbuilder --create \
  --distribution ${DIST} \
  --mirror ${MIRROR} \
  --components "main contrib non-free rpi" \
  --debootstrapopts \
  --keyring=/usr/share/keyrings/raspbian-archive-keyring.gpg \
  ${EXTRAS}
}

# get dsc files from $LINKS
get_dsc() {
    echo ` \
        curl $1 2>&1 | grep -o -E 'href="([^"#]+)"' \
            | cut -d'"' -f2 | grep ${DIST} \
            | grep dsc \
            | sort -r | head -n1 `
}

##########
# main() #
##########

if [ `whoami` != 'root' ]
then
    echo "This script needs root privileges to work"
    exit 1
fi

# check if cowbuilder is installed
if [ ! -d /var/cache/pbuilder ]
then
  install_cowbuilder
fi

# check if RPi basepath exists
if [ ! -d ${BASEPATH} ]
then
  setup_cowbuilder
fi

# update
env ${COWBUILDER_OPTIONS} HOME=`pwd` cowbuilder --update

# download source files
SRC=
for a in ${LINKS}
do
    for b in $( get_dsc  $a )
    do
      (cd ${DSCDIR}; dget ${a}${b})
      SRC="${SRC} ${b}"
    done
done
# download cython
(cd ${DSCDIR}; dget ${CYTHON_LINK})

# build packages
# start with cython first
env ${COWBUILDER_OPTIONS} DEBBUILDOPTS="${DEBBUILDOPTS}" \
  OTHERMIRROR="${OTHERMIRROR}" HOME=`pwd` cowbuilder --build ${DSCDIR}/cython*dsc

# then the rest
for a in ${SRC}
do
  env ${COWBUILDER_OPTIONS} DEBBUILDOPTS="${DEBBUILDOPTS}" \
    OTHERMIRROR="${OTHERMIRROR}" HOME=`pwd` cowbuilder --build ${DSCDIR}/${a}
done
