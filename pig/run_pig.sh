#!/bin/bash

#
# Wrapper around the pig program. The wrapper will build pig if required and then run it
# with  a set of default options, or options passed in.
#
# Example usage:
# ./run_pig.sh --run_user root --home_parent / --iterations 1 --tuned_setting tuned_none_sys_file_none --host_config hawkeye --sysname hawkeye --sys_type local
#

arguments="$@"
pig_opts=""
test_name="pig"
pig_wrapper_version="1.0"

curdir=`pwd`
if [[ $0 == "./"* ]]; then
	chars=`echo $0 | awk -v RS='/' 'END{print NR-1}'`
	if [[ $chars == 1 ]]; then
		run_dir=`pwd`
	else
		run_dir=`echo $0 | cut -d'/' -f 1-${chars} | cut -d'.' -f2-`
		run_dir="${curdir}${run_dir}"
	fi
elif [[ $0 != "/"* ]]; then
	dir=`echo $0 | rev | cut -d'/' -f2- | rev`
	run_dir="${curdir}/${dir}"
else
	chars=`echo $0 | awk -v RS='/' 'END{print NR-1}'`
	run_dir=`echo $0 | cut -d'/' -f 1-${chars}`
	if [[ $run_dir != "/"* ]]; then
		run_dir=${curdir}/${run_dir}
	fi
fi

regression=""

usage()
{
	echo "$1 usage:"
	echo "  --pig_opts: options to pass directly to pig"
	echo "  --regression: If present, we run a limted pig test. 8 points, 120 seconds each point"
	echo "  --tools_git: Pointer to the test_tools git.  Default is ${tools_git}.  Top directory is always test_tools"
	source test_tools/general_setup --usage
	exit
}

#
# Clone the repo that contains the common code and tools
#
tools_git=https://github.com/redhat-performance/test_tools-wrappers

found=0
show_usage=0
for arg in "$@"; do
	if [ $found -eq 1 ]; then
		tools_git=$arg
		found=0
	fi
	if [[ $arg == "--tools_git" ]]; then
		found=1
	fi

	#
	# We do the usage check here, as we do not want to be calling
	# the common parsers then checking for usage here.  Doing so will
	# result in the script exiting with out giving the test options.
	#
	if [[ $arg == "--usage" ]]; then
		show_usage=1
	fi
done

#
# Check to see if the test tools directory exists.  If it does, we do not need to
# clone the repo.
#
if [ ! -d "test_tools" ]; then
        git clone $tools_git test_tools
        if [ $? -ne 0 ]; then
                echo pulling git $tools_git failed.
                exit
        fi
fi

if [ $show_usage -eq 1 ]; then
	usage $0
fi

# Variables set by general setup.
#
# TOOLS_BIN: points to the tool directory
# to_home_root: home directory
# to_configuration: configuration information
# to_times_to_run: number of times to run the test
# to_run_label: Label for the run
# to_user: User on the test system running the test
# to_sys_type: for results info, basically aws, azure or local
# to_sysname: name of the system
# to_tuned_setting: tuned setting
# to_use_pcp: flag to indicate if pcp should be used
#

source test_tools/general_setup "$@"

#
# Define options
#
ARGUMENT_LIST=(
	"pig_opts"
)

NO_ARGUMENTS=(
	"regression"
)

# read arguments
opts=$(getopt \
    --longoptions "$(printf "%s:," "${ARGUMENT_LIST[@]}")" \
    --longoptions "$(printf "%s," "${NO_ARGUMENTS[@]}")" \
    --name "$(basename "$0")" \
    --options "h" \
    -- "$@"
)

if [ $? -ne 0 ]; then
	usage "${0}"
fi

eval set --$opts

while [[ $# -gt 0 ]]; do
        case "$1" in
		--pig_opts)
			pig_opts=${OPTARG}
			shift 2
		;;
		--regression)
			regression="-r"
			shift 1
		;;
		-h)
			usage "${0}"
		;;
		--)
			break; 
		;;
		*)
			echo option not found $1
			usage "${0}"
		;;
        esac
done
shift $((OPTIND-1))

#
# Reduce the data.
#
produce_results_info()
{
	grep -H "#CPUS:" iteration* | cut -d: -f 4,5 | sed "s/  / /g" | cut -d' ' -f 2,4 | sort -n -k2 > temp_data

	if [[ -f results_${test_name}.csv ]]; then
		rm results_${test_name}.csv > /dev/null
	fi
	$TOOLS_BIN/test_header_info --front_matter --results_file results_${test_name}.csv --host $to_configuration --sys_type $to_sys_type --tuned $to_tuned_setting --results_version $pig_wrapper_version --test_name $test_name

	printf "%11s %11s\n"  "#threads" "sched_eff" > results.txt
	echo  "#threads" "sched_eff" >> results_${test_name}.csv
	cpu_total=0
	thread_total=0
	thread_cnt=""
	while IFS= read -r data
	do
		cpus=`echo $data | cut -d' ' -f1`
		threads=`echo $data | cut -d' ' -f2`
		if [[ $thread_cnt == "" ]]; then
			cpu_total=$cpus
			thread_total=$threads
			thread_cnt=$threads
			continue
		fi
		if [[ $thread_cnt == $threads ]]; then
			let "cpu_total=$cpu_total+$cpus"
			let "thread_total=$thread_total+$threads"
			continue
		fi
		value=`echo "scale=2;$cpu_total/$thread_total" | bc`
		echo $thread_cnt:$value >> results_${test_name}.csv
		printf "%11s %11s\n" $thread_cnt $value >> results.txt
		cpu_total=$cpus
		thread_cnt=$threads
		thread_total=$threads
	done < "temp_data"
	value=`echo "scale=2;$cpu_total/$thread_total" | bc`
	echo $thread_cnt:$value >> results_${test_name}.csv
	printf "%11s %11s\n" $thread_cnt $value >> results.txt
	thread_cnt=$threads
	thread_total=$threads
	lines=`wc -l results_${test_name}.csv | cut -d' ' -f 1`
	if [ $lines -gt 2 ]; then
		echo Ran > test_results_report
	else
		echo Failed > test_results_report
	fi
}
#
# Run the pig test itself.
#
run_pig_test()
{
	pushd $run_dir > /dev/null
	#
	# Build pig if it is not present.
	# $regression will either be a null string or -r
	#
	if [ ! -x ./pig ]; then
		gcc pig.c -o pig -lm -lpthread -lnuma
	fi
	if [[ $pig_opts == "" ]]; then
		./run_pig -i $to_times_to_run -t $to_tuned_setting $to_sysname $regression
	else
		opts=`echo $pig_opts | cut -d: -f 2 | sed "s/\"//g"`
		suffix=`echo $pig_opts | cut -d: -f 1 | sed "s/\"//g"`
		info="${config_name}_${suffix}"
		./run_pig -i $to_times_to_run -t $to_tuned_setting -p "${opts}" -s $info $regression
	fi
	popd > /dev/null
}

test_tools/package_tool --wrapper_config "${run_dir}/pig.json" --no_packages "$to_no_pkg_install"
if [[ $? -ne 0 ]]; then
	exit_out "package_tool reported failure installing dependencies."
fi

# Get PCP setup if we're using it
if [[ $to_use_pcp -eq 1 ]]; then
	source $TOOLS_BIN/pcp/pcp_commands.inc
	setup_pcp
	pcp_cfg=$TOOLS_BIN/pcp/default.cfg
	pcpdir=/tmp/pcp_`date "+%Y.%m.%d-%H.%M.%S"`
fi

#
# Check to see if we have a parameters file to use.
#
file=`${TOOLS_BIN}/get_params_file -d /$to_home_root/${to_user} -c ${config_name} -t ${test_name}`

# If we're using PCP start logging
if [[ $to_use_pcp -eq 1 ]]; then
        echo "Start PCP"
       	start_pcp ${pcpdir}/ ${test_name} $pcp_cfg
fi

if test -f "$file"; then
	#
	# We have a parameters file to use, walk through each line.
	#
	while IFS= read -r pig_opts
	do
		run_pig_test
	done < "$file"
else
	#
	# Run default test
	#
	run_pig_test 
fi

# If we're using PCP, stop logging
if [[ $to_use_pcp -eq 1 ]]; then
        echo "Stop PCP"
        stop_pcp
fi

# Shutdown PCP and clean up after ourselves
if [[ $to_use_pcp -eq 1 ]]; then
    	shutdown_pcp
fi

cd $run_dir
cd results_${test_name}_${to_tuned_setting} 
produce_results_info
cd ..
#
# Save the results for later.
#
if [[ $to_use_pcp -eq 1 ]]; then
	cp -R ${pcpdir} results_${test_name}_${to_tuned_setting}
fi
${curdir}/test_tools/save_results --curdir $curdir --home_root $to_home_root --copy_dir results_${test_name}_${to_tuned_setting} --test_name $test_name --tuned_setting=$to_tuned_setting --version NONE --user $to_user
