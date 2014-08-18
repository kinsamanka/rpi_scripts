#!/bin/sh

DIST=wheezy
NUM_CORES=3

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

MIRROR='http://mirrordirector.raspbian.org/raspbian'

DSCDIR="`pwd`/src_files"

BUILDPLACE="`pwd`/build"
BASEPATHROOT="`pwd`/raspbian"
BASEPATH="${BASEPATHROOT}/base.cow"
BUILDRESULT="`pwd`/result"
HOOKDIR="`pwd`/hooks"
APTCACHE="`pwd`/aptcache"

BINDMOUNTS="${BUILDRESULT}"
EXTRAPACKAGES="apt-utils"
DEBBUILDOPTS="-I -i -j${NUM_CORES}"
OTHERMIRROR="deb [trusted=yes] file://${BUILDRESULT} ./"

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

  mkdir -p ${APTCACHE}
  mkdir -p ${BASEPATHROOT}
  mkdir -p ${BUILDPLACE}
  mkdir -p ${BUILDRESULT}
  mkdir -p ${DSCDIR}
  mkdir -p ${HOOKDIR}

  # create pbuilderrc
  a=`pwd`/.pbuilderrc
  cat <<EOF > ${a}
APTCACHE="${APTCACHE}"
APTCACHEHARDLINK="yes"
BASEPATH="${BASEPATH}"
BINDMOUNTS="${BINDMOUNTS}"
BUILDPLACE="${BUILDPLACE}"
BUILDRESULT="${BUILDRESULT}"
DEBBUILDOPTS="${DEBBUILDOPTS}"
DISTRIBUTION="${DIST}"
EXTRAPACKAGES="${EXTRAPACKAGES}"
HOOKDIR="${HOOKDIR}"
OTHERMIRROR="deb [trusted=yes] file://${BUILDRESULT} ./"
EOF

  # create hooks
  cat <<EOF > ${HOOKDIR}/D05Deps
(cd ${BUILDRESULT}; apt-ftparchive packages . > Packages)
apt-get update
EOF
  chmod +x ${HOOKDIR}/D05Deps
  
  # create temporaty Packages file, otherwise cowbuilder fails
  cat <<EOF > ${BUILDRESULT}/Packages
Package: test-doc
EOF

  HOME=`pwd` cowbuilder --create \
  --distribution ${DIST} \
  --mirror ${MIRROR} \
  --components "main contrib non-free rpi" \
  --debootstrapopts \
  --keyring=/usr/share/keyrings/raspbian-archive-keyring.gpg \
  ${EXTRAS} || exit 1
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
HOME=`pwd` cowbuilder --update

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
HOME=`pwd` cowbuilder --build ${DSCDIR}/cython*dsc || exit 1

# then the rest
for a in ${SRC}
do
  HOME=`pwd` cowbuilder --build ${DSCDIR}/${a} || exit 1
done
