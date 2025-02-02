#!/bin/bash
set -x

cleanup() {
echo '--> Cleaning up...'
sudo rm -fv /etc/rpm/platform
rm -fv /etc/mock-urpm/default.cfg
sudo rm -rf /var/lib/mock-urpm/*

# unmask/mask both, we need to keep logs
#rm -rf ${HOME}/output/
#rm -fv ~/build_fail_reason.log

# (tpg) remove package
rm -rf "${HOME}/${PACKAGE:?}"
# (tpg) remove old files
# in many cases these are leftovers when build fails
# would be nice to remove them to free disk space
find ${HOME} -maxdepth 1 ! -name 'qemu-a*' ! -name 'docker-worker' ! -name '.gem' ! -name 'envfile' -mmin +1500 -exec rm -rf '{}' \;  &> /dev/null
}

# (tpg) Clean build environment
cleanup

# (tpg) remove these files
[ -e ~/build_fail_reason.log ] && rm -rf ~/build_fail_reason.log
[ -e "${HOME}"/output ] && rm -rf "${HOME}"/output

MOCK_BIN="/usr/bin/mock-urpm"
config_dir=/etc/mock-urpm/
# $PACKAGE same as project name
# e.g. github.com/OpenMandrivaAssociation/htop
build_package=${HOME}/"$PACKAGE"
OUTPUT_FOLDER=${HOME}/output

GREP_PATTERN='error: (.*)$|Segmentation Fault|cannot find (.*)$|undefined reference (.*)$|cp: (.*)$|Hunk #1 FAILED|\(due to unsatisfied(.*)$'

filestore_url="http://file-store.rosalinux.ru/api/v1/file_stores"
platform_arch="$PLATFORM_ARCH"
platform_name="$PLATFORM_NAME"
uname="$UNAME"
email="$EMAIL"
git_repo="$GIT_PROJECT_ADDRESS"
project_version="$PROJECT_VERSION"
extra_build_rpm_options="$EXTRA_BUILD_RPM_OPTIONS"
extra_build_src_rpm_options="$EXTRA_BUILD_SRC_RPM_OPTIONS"
extra_cfg_options="$EXTRA_CFG_OPTIONS"
extra_cfg_urpm_options="$EXTRA_CFG_URPM_OPTIONS"
save_buildroot="$SAVE_BUILDROOT"
use_extra_tests="$USE_EXTRA_TESTS"
rerun_tests="$RERUN_TESTS"
commit_hash="$COMMIT_HASH"
# list of packages for tests relaunch
packages="$PACKAGES"

if [ "$(uname -m)" = 'x86_64' ] && echo "$platform_arch" |grep -qE 'i[0-9]86'; then
    # Change the kernel personality so build scripts don't think
    # we're building for 64-bit
    MOCK_BIN="/usr/bin/i386 $MOCK_BIN"
fi

generate_config() {
# Change output format for mock-urpm
sed '17c/format: %(message)s' $config_dir/logging.ini > ~/logging.ini
mv -f ~/logging.ini $config_dir/logging.ini

EXTRA_CFG_OPTIONS="$extra_cfg_options" \
  EXTRA_CFG_URPM_OPTIONS="$extra_cfg_urpm_options" \
  UNAME=$uname \
  EMAIL=$email \
  PLATFORM_NAME=$platform_name \
  PLATFORM_ARCH=$platform_arch \
  /bin/bash "/mdv/config-generator.sh"
}

container_data() {
# Generate data for container

[ "$rerun_tests" = 'true' ] && return 0

c_data=$OUTPUT_FOLDER/container_data.json
project_name=`echo ${git_repo} | sed s%.*/%% | sed s/.git$//`
echo '[' > ${c_data}
comma=0
for rpm in ${OUTPUT_FOLDER}/*.rpm; do
    nevr=(`rpm -qp --queryformat "%{NAME} %{EPOCH} %{VERSION} %{RELEASE}" ${rpm}`)
    name=${nevr[0]}
    if [ "${name}" != '' ] ; then
	if [ $comma -eq 1 ]
	then
		echo -n "," >> ${c_data}
	fi
	if [ $comma -eq 0 ]
	then
		comma=1
	fi
	fullname=`basename $rpm`
	epoch=${nevr[1]}
	version=${nevr[2]}
	release=${nevr[3]}

	dep_list=""
	[[ ! "${fullname}" =~ ".*src.rpm$" ]] && dep_list=`sudo urpmq --whatrequires --sourcerpm "${name}" | cut -d\  -f2 | rev | cut -f3- -d- | rev | sort -u | grep -v "^${project_name}$" | xargs echo`
	sha1=`sha1sum ${rpm} | awk '{ print $1 }'`

	echo "--> dep_list for '${name}':"
	echo ${dep_list}

	echo '{' >> ${c_data}
	echo "\"dependent_packages\":\"${dep_list}\","    >> ${c_data}
	echo "\"fullname\":\"${fullname}\","              >> ${c_data}
	echo "\"sha1\":\"${sha1}\","                      >> ${c_data}
	echo "\"name\":\"${name}\","                      >> ${c_data}
	echo "\"epoch\":\"${epoch}\","                    >> ${c_data}
	echo "\"version\":\"${version}\","                >> ${c_data}
	echo "\"release\":\"${release}\""                 >> ${c_data}
	echo '}' >> ${c_data}
    fi
done
echo ']' >> ${c_data}

}

download_cache() {

if [ "${CACHED_CHROOT_SHA1}" != '' ]; then
# if chroot not exist download it
    if [ ! -f ${HOME}/${CACHED_CHROOT_SHA1}.tar.xz ]; then
	curl -L "${filestore_url}/${CACHED_CHROOT_SHA1}" -o "${HOME}/${CACHED_CHROOT_SHA1}.tar.xz"
    fi
# unpack in root
    echo "Extracting chroot $CACHED_CHROOT_SHA1"
    if echo "${CACHED_CHROOT_SHA1} ${HOME}/${CACHED_CHROOT_SHA1}.tar.xz" | sha1sum -c --status &> /dev/null; then
	sudo tar -xf ${HOME}/${CACHED_CHROOT_SHA1}.tar.xz -C /
    else
	echo '--> Building without cached chroot, becasue SHA1 is wrong.'
	export CACHED_CHROOT_SHA1=""
    fi
fi

}

arm_platform_detector(){
probe_cpu() {
# probe cpu type
cpu="$(uname -m)"
case "$cpu" in
   i386|i486|i586|i686|i86pc|BePC|x86_64)
      cpu="i386"
   ;;
   armv[4-9]*)
      cpu="arm"
   ;;
   aarch64)
      cpu="aarch64"
   ;;
esac

if [ "$platform_arch" = 'aarch64' ]; then
    if [ $cpu != "aarch64" ] ; then
# hack to copy qemu binary in non-existing path
	(while [ ! -e  /var/lib/mock-urpm/$platform_name-$platform_arch/root/usr/bin/ ]
	do sleep 1; done
	# rebuild docker builder with qemu packages
	sudo cp /usr/bin/qemu-static-aarch64 /var/lib/mock-urpm/$platform_name-$platform_arch/root/usr/bin/) &
	subshellpid=$!
    fi
# remove me in future
    sudo sh -c "echo '$platform_arch-mandriva-linux-gnueabi' > /etc/rpm/platform"
fi

if [ "$platform_arch" = 'armv7hl' ]; then
    if [ $cpu != "arm" ] || [ $cpu != "aarch64" ] ; then
# hack to copy qemu binary in non-existing path
	(while [ ! -e  /var/lib/mock-urpm/$platform_name-$platform_arch/root/usr/bin/ ]
	do sleep 1; done
	sudo cp /usr/bin/qemu-static-arm /var/lib/mock-urpm/$platform_name-$platform_arch/root/usr/bin/) &
	subshellpid=$!
    fi
# remove me in future
    sudo sh -c "echo '$platform_arch-mandriva-linux-gnueabi' > /etc/rpm/platform"
fi

}
probe_cpu
}

test_rpm() {
# Rerun tests
    PACKAGES=${packages} \
    chroot_path="$($MOCK_BIN --configdir=$config_dir --print-root-path)" \
    use_extra_tests=$use_extra_tests

    test_code=0
    test_log="$OUTPUT_FOLDER"/tests.log
    echo '--> Starting RPM tests.'

    if [ "$rerun_tests" = 'true' ]; then
	[ "$packages" = '' ] && echo '--> No packages for testing. Something is wrong. Exiting. !!!' && exit 1

	[ ! -e "$OUTPUT_FOLDER" ] && mkdir -p "$OUTPUT_FOLDER"
	[ ! -e "$build_package" ] && mkdir -p "$build_package"

	test_log="$OUTPUT_FOLDER"/tests-`printf '%(%F-%R)T'.log`
	echo "--> Re-running tests on `date -u`" >> $test_log
	prefix='rerun-tests-'
	arr=($packages)
	pushd "$build_package"
	for package in ${arr[@]} ; do
	    echo "--> Downloading '$package'..." >> $test_log
	    wget http://file-store.rosalinux.ru/api/v1/file_stores/$package --content-disposition --no-check-certificate
	    rc=$?
		if [ $rc != 0 ]; then
		    echo "--> Error on extracting package with sha1 '$package'!!!"
		    exit $rc
		fi
	    done
	popd
	$MOCK_BIN --init --configdir $config_dir -v --no-cleanup-after
	OUTPUT_FOLDER="$build_package"
    fi

	echo '--> Checking if rpm packages can be installed.' >> $test_log
	$MOCK_BIN -v --init --configdir $config_dir $OUTPUT_FOLDER/*.src.rpm >> "${test_log}"
	$MOCK_BIN -v --init --configdir $config_dir --install $(ls "$OUTPUT_FOLDER"/*.rpm | grep -v .src.rpm) >> "${test_log}" 2>&1
	test_code=$?
	if [ $test_code == 0 ]; then
		# enable all repos first
		# needed for debug packages mostly
		#python /mdv/enable_all_repos.py $chroot_path http://abf-downloads.rosalinux.ru/${platform_name}/repository/${platform_arch}/
		echo '--> Checking if same or newer version of the package already exists in repositories' >> $test_log 2>&1
		python /mdv/check_newer_versions.py $chroot_path >> $test_log 2>&1
		test_code=$?
		echo "--> Tests finished at `date -u`" >> $test_log
		echo 'Test code output: ' $test_code >> $test_log 2>&1
	fi

	# Check exit code after testing
	if [ $test_code != 0 ]; then
	    echo '--> Test failed, see: tests.log'
	    test_code=5
	    [ "$rerun_tests" = '' ] && container_data
	    [ "$rerun_tests" = 'true' ] && cleanup
	    exit $test_code
	else
	    return $test_code
	fi
}

build_rpm() {
arm_platform_detector

# We will rerun the build in case when repository is modified in the middle,
# but for safety let's limit number of retest attempts
# (since in case when repository metadata is really broken we can loop here forever)


MAX_RETRIES=10
WAIT_TIME=60
RETRY_GREP_STR="You may need to update your urpmi database\|problem reading synthesis file of medium\|retrieving failed: "

if [ "$rerun_tests" = 'true' ]; then
    test_rpm
    return 0
fi

sudo touch -d "23 hours ago" $config_dir/default.cfg

spec_name=`ls -1 $build_package | grep '\.spec$'`
echo '--> Build src.rpm'
try_rebuild=true
retry=0
while $try_rebuild
do
    rm -rf "${OUTPUT_FOLDER}"
    if [ "${CACHED_CHROOT_SHA1}" != '' ]; then
	echo "--> Uses cached chroot with sha1 '$CACHED_CHROOT_SHA1'..."
	$MOCK_BIN --chroot "urpmi.removemedia -a"
	$MOCK_BIN --readdrepo -v --configdir $config_dir
# (tpg) catch errors when adding repositories into chroot
	rc=${PIPESTATUS[0]}
	try_rebuild=false
	if [[ $rc != 0 && $retry < $MAX_RETRIES ]]; then
	    if grep -q "$RETRY_GREP_STR" $OUTPUT_FOLDER/root.log; then
		try_rebuild=true
		(( retry=$retry+1 ))
		echo "--> Repository was changed in the middle, will rerun the build. Next try (${retry} from ${MAX_RETRIES})..."
		echo "--> Delay ${WAIT_TIME} sec..."
		sleep ${WAIT_TIME}
	    fi
	fi
	$MOCK_BIN -v --configdir=$config_dir --buildsrpm --spec=$build_package/${spec_name} --sources=$build_package --no-cleanup-after --no-clean $extra_build_src_rpm_options --resultdir=$OUTPUT_FOLDER
	rc=${PIPESTATUS[0]}
	python /mdv/check_arch.py "${OUTPUT_FOLDER}"/*.src.rpm ${platform_arch}
	if [[ $? -ne 0 ]]; then exit 6; fi
    else
	$MOCK_BIN -v --configdir=$config_dir --buildsrpm --spec=$build_package/${spec_name} --sources=$build_package --no-cleanup-after $extra_build_src_rpm_options --resultdir=$OUTPUT_FOLDER
	rc=${PIPESTATUS[0]}
	python /mdv/check_arch.py "${OUTPUT_FOLDER}"/*.src.rpm ${platform_arch}
	if [[ $? -ne 0 ]]; then exit 6; fi
    fi

    try_rebuild=false
    if [[ $rc != 0 && $retry < $MAX_RETRIES ]]; then
	if grep -q "$RETRY_GREP_STR" $OUTPUT_FOLDER/root.log; then
	    try_rebuild=true
	    (( retry=$retry+1 ))
	    echo "--> Repository was changed in the middle, will rerun the build. Next try (${retry} from ${MAX_RETRIES})..."
	    echo "--> Delay ${WAIT_TIME} sec..."
	    sleep ${WAIT_TIME}
	fi
    fi
done

# Check exit code after build
if [ $rc != 0 ] || [ ! -e $OUTPUT_FOLDER/*.src.rpm ]; then
    echo '--> Build failed: mock-urpm encountered a problem.'
    # 99% of all build failures at src.rpm creation is broken deps
    # m1 show only first match -oP show only matching
    grep -m1 -oP "\(due to unsatisfied(.*)$" $OUTPUT_FOLDER/root.log >> ~/build_fail_reason.log
    [ -n $subshellpid ] && kill $subshellpid
    cleanup
    exit 1
fi

echo '--> src.rpm build has been done successfully.'

echo '--> Building rpm'
try_rebuild=true
retry=0
while $try_rebuild
do
    $MOCK_BIN --chroot "urpmi.removemedia -a" --resultdir=$OUTPUT_FOLDER
    $MOCK_BIN --readdrepo -v --configdir $config_dir --resultdir=$OUTPUT_FOLDER
    $MOCK_BIN -v --configdir=$config_dir --rebuild $OUTPUT_FOLDER/*.src.rpm --no-cleanup-after --no-clean $extra_build_rpm_options --resultdir=$OUTPUT_FOLDER
    rc=${PIPESTATUS[0]}
    try_rebuild=false
    if [[ $rc != 0 && $retry < $MAX_RETRIES ]] ; then
	if grep -q "$RETRY_GREP_STR" $OUTPUT_FOLDER/root.log; then
	    try_rebuild=true
	    (( retry=$retry+1 ))
	    echo "--> Repository was changed in the middle, will rerun the build. Next try (${retry} from ${MAX_RETRIES})..."
	    echo "--> Delay ${WAIT_TIME} sec..."
	    sleep ${WAIT_TIME}
	fi
    fi
done

echo '--> Create rpm -qa list'
CHROOT_PATH="$($MOCK_BIN --configdir=$config_dir --print-root-path)"
rpm --root="$CHROOT_PATH" -qa > "$OUTPUT_FOLDER/rpm-qa.log"

# (tpg) Save build chroot
if [ "${rc}" != 0 ] && [ "${save_buildroot}" = 'true' ]; then
    sudo tar --exclude=root/dev -zcvf "${OUTPUT_FOLDER}"/rpm-buildroot.tar.gz /var/lib/mock-urpm/$platform_name-$platform_arch/root/
fi
# Check exit code after build
if [ $rc != 0 ]; then
    echo '--> Build failed: mock-urpm encountered a problem.'
# clean all the rpm files because build was not completed
    grep -m1 -i -oP "$GREP_PATTERN" $OUTPUT_FOLDER/root.log >> ~/build_fail_reason.log
    rm -rf $OUTPUT_FOLDER/*.rpm
    [ -n $subshellpid ] && kill $subshellpid
    cleanup
    exit 1
fi
echo '--> Done.'

# Extract rpmlint logs into separate file
echo "--> Grepping rpmlint logs from $OUTPUT_FOLDER/build.log to $OUTPUT_FOLDER/rpmlint.log"
sed -n "/Executing \"\/usr\/bin\/rpmlint/,/packages and.*specfiles checked/p" $OUTPUT_FOLDER/build.log > $OUTPUT_FOLDER/rpmlint.log


# Test RPM files
if [ "$use_extra_tests" = 'true' ]; then
    test_rpm
fi
# End tests

}

find_spec() {

[ "$rerun_tests" = 'true' ] && return 0

# Check count of *.spec files (should be one)
x=$(ls -1 | grep -c '\.spec$' | sed 's/^ *//' | sed 's/ *$//')
if [ "$x" -eq "0" ] ; then
    echo '--> There are no spec files in repository.'
    exit 1
else
    if [ "$x" -ne "1" ] ; then
	echo '--> There are more than one spec file in repository.'
	exit 1
    fi
fi
}


clone_repo() {

[ "$rerun_tests" = 'true' ] && return 0

MAX_RETRIES=5
WAIT_TIME=60
try_reclone=true
retry=0
while $try_reclone
do
    rm -rf ${HOME}/${PACKAGE:?}
# checkout specific branch/tag if defined
    if [ ! -z "$project_version" ]; then
	git clone -b $project_version $git_repo ${HOME}/${PACKAGE}
	pushd ${HOME}/${PACKAGE}
	git rev-parse HEAD > ${HOME}/commit_hash
	popd
    else
	git clone $git_repo ${HOME}/${PACKAGE}
	pushd ${HOME}/${PACKAGE}
		echo ${commit_hash} > ${HOME}/commit_hash
		git checkout $commit_hash
	popd
    fi
    rc=$?
    try_reclone=false
    if [[ $rc != 0 && $retry < $MAX_RETRIES ]] ; then
	try_reclone=true
	(( retry=$retry+1 ))
	echo "--> Something wrong with git repository, next try (${retry} from ${MAX_RETRIES})..."
	echo "--> Delay ${WAIT_TIME} sec..."
	sleep ${WAIT_TIME}
    fi
done

pushd ${HOME}/${PACKAGE}
# count number of specs (should be 1)
find_spec
# download sources from .abf.yml
/bin/bash /mdv/download_sources.sh
popd

# build package
}

generate_config
clone_repo
download_cache
build_rpm
container_data
# wipe package
rm -rf ${HOME}/${PACKAGE:?}
