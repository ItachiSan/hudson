#!/usr/bin/env bash

JOBS_NUM=$(cat /proc/cpuinfo | grep "^processor" | wc -l)

function check_result {
  if [ "0" -ne "$?" ]
  then
    local err_message=${1:-""}
    local exit_die=${2:-"true"}
    local rm_roomservice=${3:-"true"}
    (repo forall -c "git reset --hard; git clean -fdx") >/dev/null
    rm -f .repo/local_manifests/dyn-*.xml
    if [ "$rm_roomservice" = "true" ]
    then
      rm -f .repo/local_manifests/roomservice.xml
    fi
    echo $err_message
    if [ "$exit_die" = "true" ]
    then
      exit 1
    fi
  fi
}

if [ -z "$HOME" ]
then
  echo HOME not in environment, guessing...
  export HOME=$(awk -F: -v v="$USER" '{if ($1==v) print $6}' /etc/passwd)
fi

if [ -z "$WORKSPACE" ]
then
  echo WORKSPACE not specified
  exit 1
fi

if [ ! -z "$GERRIT_BRANCH" ]
then
  export REPO_BRANCH=$GERRIT_BRANCH
fi

if [ -z "$REPO_BRANCH" ]
then
  echo REPO_BRANCH not specified
  exit 1
fi

if [ ! -z "$GERRIT_PROJECT" ]
then
  export RELEASE_TYPE=AUTOTEST
  export CM_EXTRAVERSION="gerrit-$GERRIT_CHANGE_NUMBER-$GERRIT_PATCHSET_NUMBER"
  export CLEAN=true
  export GERRIT_XLATION_LINT=true
  export VIRUS_SCAN=true

  vendor_name=$(echo $GERRIT_PROJECT | grep -Po '.*(?<=android_device_)[^_]*' | sed -e s#android-legacy/android_device_##g)
  device_name=$(echo $GERRIT_PROJECT | grep '.*android_device_[^_]*_' | sed -e s#.*android_device_[^_]*_##g | sed s#android-legacy/##g )

  if [[ "$GERRIT_PROJECT" == *kernel* ]]
  then
    vendor_name=$(echo $GERRIT_PROJECT | grep -Po '.*(?<=android_kernel_)[^_]*' | sed -e s#android-legacy/android_kernel_##g)
    device_name=msm7x27-common
  fi

  if [[ "$GERRIT_PROJECT" == *vendor_google* ]]
  then
    export MINI_GAPPS=true
  fi

  if [[ "$GERRIT_PROJECT" == "android-legacy/android" ]]
  then
    export CHERRYPICK_REV=$GERRIT_PATCHSET_REVISION
  fi

  # LDPI device (default)
  LUNCH=cm_jenad-userdebug
  if [ ! -z $vendor_name ] && [ ! -z $device_name ]
  then
    # Workaround for failing translation checks in common device repositories
    LUNCH=$(echo cm_$device_name-userdebug@$vendor_name | sed -f $WORKSPACE/hudson/android-legacy-shared-repo.map)
  fi
  export LUNCH=$LUNCH
fi

if [ -z "$LUNCH" ]
then
  echo LUNCH not specified
  exit 1
fi

if [ -z "$CLEAN" ]
then
  echo CLEAN not specified
  exit 1
fi

if [ -z "$RELEASE_TYPE" ]
then
  echo RELEASE_TYPE not specified
  exit 1
fi

if [ -z "$SYNC_PROTO" ]
then
  SYNC_PROTO=git
fi

# colorization fix in Jenkins
export CL_RED="\"\033[31m\""
export CL_GRN="\"\033[32m\""
export CL_YLW="\"\033[33m\""
export CL_BLU="\"\033[34m\""
export CL_MAG="\"\033[35m\""
export CL_CYN="\"\033[36m\""
export CL_RST="\"\033[0m\""
# ICS has different 'declare's for colors
export CL_PFX="\"\033[33m\""
export CL_INS="\"\033[36m\""


cd $WORKSPACE
rm -rf archive
mkdir -p archive
export BUILD_NO=$BUILD_NUMBER
unset BUILD_NUMBER

export PATH=~/bin:$PATH
export BUILD_WITH_COLORS=0

if [[ "$RELEASE_TYPE" == "RELEASE" ]]
then
  export USE_CCACHE=0
else
  export USE_CCACHE=1
  export CCACHE_NLEVELS=4
fi

#AOKP compability
export AOKP_BUILD=$RELEASE_TYPE

REPO=$(which repo)
if [ -z "$REPO" ]
then
  mkdir -p ~/bin
  curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
  chmod a+x ~/bin/repo
fi

if [ -z "$BUILD_USER_ID" ]
then
  export BUILD_USER_ID=$(whoami)
fi

git config --global user.name $BUILD_USER_ID@android-legacy
git config --global user.email review@android-legacy.com

JENKINS_BUILD_DIR=$REPO_BRANCH

mkdir -p $JENKINS_BUILD_DIR
cd $JENKINS_BUILD_DIR

# always force a fresh repo init since we can build off different branches
# and the "default" upstream branch can get stuck on whatever was init first.
if [ -z "$CORE_BRANCH" ]
then
  CORE_BRANCH=$REPO_BRANCH
fi

if [ ! -z "$RELEASE_MANIFEST" ]
then
  MANIFEST="-m $RELEASE_MANIFEST"
else
  RELEASE_MANIFEST=""
  MANIFEST=""
fi


# remove non-core repos
rm -fr kernel/
rm -fr device/lge/
rm -fr device/samsung/
rm -fr device/zte/
rm -fr vendor/lge/
rm -fr vendor/samsung/
rm -fr vendor/zte/

# remove manifests
rm -rf .repo/manifests*
rm -f .repo/local_manifests/dyn-*.xml
rm -f .repo/local_manifest.xml
repo init -u $SYNC_PROTO://github.com/android-legacy/android.git -b $CORE_BRANCH $MANIFEST
check_result "repo init failed."
if [ ! -z "$CHERRYPICK_REV" ]
then
  cd .repo/manifests
  sleep 20
  git fetch origin $GERRIT_REFSPEC
  git cherry-pick $CHERRYPICK_REV
  cd ../..
fi

if [ $USE_CCACHE -eq 1 ]
 then
   # make sure ccache is in PATH
if [ "$REPO_BRANCH" == "ics" ]; then
  export PATH="$PATH:/opt/local/bin/:$(pwd)/prebuilt/$(uname|awk '{print tolower($0)}')-x86/ccache"
else
  export PATH="$PATH:/opt/local/bin/:$(pwd)/prebuilts/misc/$(uname|awk '{print tolower($0)}')-x86/ccache"
fi
   export CCACHE_DIR=$WORKSPACE/ccache/$JOB_NAME/$REPO_BRANCH
   mkdir -p $CCACHE_DIR
 fi


if [ -f ~/.jenkins_profile ]
then
  . ~/.jenkins_profile
fi

mkdir -p .repo/local_manifests
rm -f .repo/local_manifest.xml

echo Core Manifest:
cat .repo/manifest.xml

echo Syncing...
# if sync fails:
# clean repos (uncommitted changes are present), don't delete roomservice.xml, don't exit
repo sync -d -c -f -j$JOBS_NUM
check_result "repo sync failed.", false, false

# sync again, delete roomservice.xml if sync fails
repo sync -d -c -f -j1
check_result "repo sync failed.", false, true

# last sync, delete roomservice.xml and exit if sync fails
repo sync -d -c -f -j1
check_result "repo sync failed.", true, true

# SUCCESS
echo Sync complete.

$WORKSPACE/hudson/cm-setup.sh

if [ -f .last_branch ]
then
  LAST_BRANCH=$(cat .last_branch)
else
  echo "Last build branch is unknown, assume clean build"
  LAST_BRANCH=$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST
fi

if [ "$LAST_BRANCH" != "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" ]
then
  echo "Branch has changed since the last build happened here. Forcing cleanup."
  CLEAN="true"
fi

. build/envsetup.sh
lunch $LUNCH
check_result "lunch failed."

# save manifest used for build (saving revisions as current HEAD)
if [ -f device/samsung/msm7x27a-common/patches/install-all.sh ]
then
  device/samsung/msm7x27a-common/patches/install-all.sh
else
  echo "No patches to apply."
fi 

# include only the auto-generated locals
TEMPSTASH=$(mktemp -d)
mv .repo/local_manifests/* $TEMPSTASH
mv $TEMPSTASH/roomservice.xml .repo/local_manifests/

# save it
repo manifest -o $WORKSPACE/archive/manifest.xml -r

# restore all local manifests
mv $TEMPSTASH/* .repo/local_manifests/ 2>/dev/null
rmdir $TEMPSTASH

rm -f $OUT/cm-*.zip*

UNAME=$(uname)

# CM build tags
if [ "$RELEASE_TYPE" = "CM_NIGHTLY" ]
then
  export CM_NIGHTLY=true
elif [ "$RELEASE_TYPE" = "CM_EXPERIMENTAL" ]
then
  export CM_EXPERIMENTAL=true
elif [ "$RELEASE_TYPE" = "CM_RELEASE" ]
then
  export CM_RELEASE=true
fi

if [ ! -z "$CM_EXTRAVERSION" ]
then
  export CM_EXPERIMENTAL=true
fi


if [ ! -z "$GERRIT_CHANGE_NUMBER" ]
then
  export GERRIT_CHANGES=$GERRIT_CHANGE_NUMBER
fi

if [ ! -z "$GERRIT_CHANGES" ]
then
  export CM_EXPERIMENTAL=true
  IS_HTTP=$(echo $GERRIT_CHANGES | grep http)
  if [ -z "$IS_HTTP" ]
  then
    python $WORKSPACE/hudson/repopick.py $GERRIT_CHANGES
    check_result "gerrit picks failed."
  else
    python $WORKSPACE/hudson/repopick.py $(curl $GERRIT_CHANGES)
    check_result "gerrit picks failed."
  fi
  if [ ! -z "$GERRIT_XLATION_LINT" ]
  then
    python $WORKSPACE/hudson/xlationlint.py $GERRIT_CHANGES
    check_result "basic XML lint failed."
  fi
fi

if [ $USE_CCACHE -eq 1 ]
then
  if [ ! "$(ccache -s|grep -E 'max cache size'|awk '{print $4}')" = "20.0" ]
  then
    ccache -M 20G
  fi
  echo "============================================"
  ccache -s
  echo "============================================"
fi


rm -f $WORKSPACE/changecount
WORKSPACE=$WORKSPACE LUNCH=$LUNCH bash $WORKSPACE/hudson/changes/buildlog.sh 2>&1
if [ -f $WORKSPACE/changecount ]
then
  CHANGE_COUNT=$(cat $WORKSPACE/changecount)
  rm -f $WORKSPACE/changecount
  if [ $CHANGE_COUNT -eq "0" ]
  then
    echo "Zero changes since last build, aborting"
    exit 1
  fi
fi

LAST_CLEAN=0
if [ -f .clean ]
then
  LAST_CLEAN=$(date -r .clean +%s)
fi
TIME_SINCE_LAST_CLEAN=$(expr $(date +%s) - $LAST_CLEAN)
# convert this to hours
TIME_SINCE_LAST_CLEAN=$(expr $TIME_SINCE_LAST_CLEAN / 60 / 60)
if [ $TIME_SINCE_LAST_CLEAN -gt "24" -o $CLEAN = "true" ]
then
  echo "Cleaning!"
  touch .clean
  make clobber
else
  echo "Skipping clean: $TIME_SINCE_LAST_CLEAN hours since last clean."
fi

echo "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" > .last_branch

# envsetup.sh:mka = schedtool -B -n 1 -e ionice -n 1 make -j$(cat /proc/cpuinfo | grep "^processor" | wc -l) "$@"
# Don't add -jXX. mka adds it automatically...
if [ "$REPO_BRANCH" == "ics" ]; then
  time mka bootimage
  time mka bacon # recoveryzip recoveryimage checkapi
else
  time mka bacon
fi
check_result "Build failed."

if [ $USE_CCACHE -eq 1 ]
then
  echo "============================================"
  ccache -V
  echo "============================================"
  ccache -s
  echo "============================================"
fi

# ClamAV virus scan
if [ "$VIRUS_SCAN" = "true" ]
then
  CLAMAV_SIGNATURE=`clamdscan --version`
  echo "Scanning for viruses with $CLAMAV_SIGNATURE..."
  clamdscan --infected --multiscan --fdpass $OUT > $WORKSPACE/archive/virusreport.txt
  SCAN_RESULT=$?
  if [ $SCAN_RESULT -eq 0 ]
  then
    echo "No virus detected."
  elif [ $SCAN_RESULT -eq 1 ]
  then
    echo Virus FOUND. Removing $OUT...
    make clobber >/dev/null
    rm -fr $OUT
    if [ ! -z "$GERRIT_CHANGE_NUMBER" ] && [ ! -z "$GERRIT_PATCHSET_NUMBER" ] && [ ! -z "$BUILD_URL" ]
    then
      ssh -p 29418 $BUILD_USER_ID@review.android-legacy.com gerrit review $GERRIT_CHANGE_NUMBER,$GERRIT_PATCHSET_NUMBER --code-review -1 --message "'$BUILD_URL : VIRUS FOUND'"
    fi
    exit 1
  fi
fi

# /archive
for f in $(ls $OUT/cm-*.zip*)
do
  ln $f $WORKSPACE/archive/$(basename $f)
done
if [ -f $OUT/utilties/update.zip ]
then
  cp $OUT/utilties/update.zip $WORKSPACE/archive/recovery.zip
fi
if [ -f $OUT/recovery.img ]
then
  cp $OUT/recovery.img $WORKSPACE/archive
fi

# Clean up always; we need space on my little server.
echo "Cleaning up after the build..."
make clobber

# archive the build.prop as well
ZIP=$(ls $WORKSPACE/archive/cm-*.zip)
unzip -p $ZIP system/build.prop > $WORKSPACE/archive/build.prop

# CORE: save manifest used for build (saving revisions as current HEAD)
rm -f .repo/local_manifests/roomservice.xml

# Stash away other possible manifests
TEMPSTASH=$(mktemp -d)
mv .repo/local_manifests $TEMPSTASH

repo manifest -o $WORKSPACE/archive/core.xml -r

mv $TEMPSTASH/local_manifests .repo
rmdir $TEMPSTASH

# chmod the files in case UMASK blocks permissions
chmod -R ugo+r $WORKSPACE/archive

# Pushing through FTP daemon
# 1st is config file, than remote dir and then to-upload files (wrapper for ncftpput/ncftpbatch)
# cpftp $1 $2 $3 -> ncftpput -f $1 -b $2 $3
# Then run ncftpbatch as jenkins, here or in a cronjob
if [ "$EXPORT" = "true" ]
then
cpftp /opt/android/afh.cfg jenkins/android-legacy/$REPO_BRANCH/$BUILD_NO $WORKSPACE/archive/cm-*.zip
fi

# Leave this here, maybe I'll use it sometimes
CMCP=$(which cmcp)
if [ ! -z "$CMCP" -a ! -z "$CM_RELEASE" ]
then
  MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.modversion | cut -d = -f 2)
  if [ -z "$MODVERSION" ]
  then
    MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.cm.version | cut -d = -f 2)
  fi
  if [ -z "$MODVERSION" ]
  then
    echo "Unable to detect ro.modversion or ro.cm.version."
    exit 1
  fi
  echo Archiving release to S3.
  for f in $(ls $WORKSPACE/archive)
  do
    cmcp $WORKSPACE/archive/$f release/$MODVERSION/$f > /dev/null 2> /dev/null
    check_result "Failure archiving $f"
  done
fi
