#!/bin/bash

#################################################
# Script to run test cases defined in a Json file
# Author: Thorsten Reimers
# Date: 15.06.2024
#################################################

# print help
function printhelp() {
	echo "Run test cases from Json file"
	echo "Usage:"
	echo "	$0 -f <json-file> [-c <test-id>,...] [-p] [-v] [-x]"
	echo "Options:"
	echo "	-f <file>: json test file [REQUIRED]"
	echo "	-c <list>: list of test cases [OPTIONAL]"
	echo "	-p: skip pre-requisites [OPTIONAL]"
	echo "	-v: verbose [OPTIONAL]"
	echo "	-x: xtrace [OPTIONAL]"
	echo "Example:"
	echo "	$0 -f testCases.json -c KV1,KV2"
	exit 0
}

# check jq installed
function checkjq() {
	which jq > /dev/null 2> /dev/null
	if [[ $? -ne 0 ]]
	then
		echo "jq command-line JSON processor is missing on your path, please install jq in order to run this script."
		echo "You can download jq from https://stedolan.github.io/jq/"
		exit 1
	fi
}

# convert time difference between two dates to hours-minutes-seconds
function timeconvert() {
	if [[ "$OSTYPE" == "darwin"* ]]
	then
		start=`date -jf "%Y-%m-%d %H:%M:%S" "$1" +%s`
		end=`date -jf "%Y-%m-%d %H:%M:%S" "$2" +%s`
	elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
		start=`date -d "$1" +%s`
		end=`date -d "$2" +%s`
	else
	    echo "Unsupported OS: $OSTYPE"
    exit 1
	fi
	diffSeconds="$(($end-$start))"
	hours=$(($diffSeconds / 3600))
	minutes=$((($diffSeconds / 60) % 60))
	seconds=$(($diffSeconds % 60))
	printf "Duration: %02d:%02d:%02d" $hours $minutes $seconds
}


# handle vars
function handleVars() {
	export title=`jq --tab -r '.tests.name' < ${file} | tr -d '\r'`
	length=`jq '.tests.vars | length' < ${file} | tr -d '\r'`
	if [[ length -gt 0 ]]
	then
		sequence=`seq 0 $(( ${length} - 1 ))`
		for i in ${sequence}
		do
			index=$(( $i + 1))
			var=`jq --tab '.tests.vars['${i}']' < ${file} | tr -d '\r'`
			name=`echo ${var} | jq -r '.name // empty' | tr -d '\r'`
			value=`echo ${var} | jq -r '.value // empty' | tr -d '\r'`
			# https://stackoverflow.com/questions/9871458/declaring-global-variable-inside-a-function
			eval printf -v "${name}" "${value}"
			export "${name}"
			echo "[${index}] ${name}=${value}" >> ${runsDir}/vars.txt
			htmlVars="${htmlVars} <tr><td>${index}</td><td>${name}</td><td>${value}</td></tr>"
		done
	fi
	export htmlVars
}

# handle prerequisites
function handlePreReqs() {
	local success=0
	length=`jq '.tests.prerequisites | length' < ${file} | tr -d '\r'`
	if [[ length -gt 0 ]]
	then
		sequence=`seq 0 $(( ${length} - 1 ))`
		for i in ${sequence}
		do
			index=$(( $i + 1))
			preReq=`jq --tab '.tests.prerequisites['${i}']' < ${file} | tr -d '\r'`
			description=`echo ${preReq} | jq -r '.description // empty' | tr -d '\r'`
			command=`echo ${preReq} | jq -r '.command // empty' | tr -d '\r'`
			cmd=`echo ${command} | envsubst`
			echo ${cmd} > ${prereqsDir}/${index}.prerequisite.command.txt
			startdate=`date +"%Y-%m-%d %H:%M:%S"`
			if [[ -n ${command} ]]
			then
				if [[ ${skipPrerequisites} -eq 1 ]]
				then
					enddate=`date +"%Y-%m-%d %H:%M:%S"`
					time=`timeconvert "${startdate}" "${enddate}"`
					printf "%-18s: %-7s [${startdate} - ${enddate}] ${description}\n" "Pre-Requisite[${index}]" Skipped
					htmlPreReqs="${htmlPreReqs} <tr><td>${index}</td><td><span class=\"skipped\">✓</span> Skipped</td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td><span class=\"tooltip\">${description}<span class=\"right\">${cmd}</span></span></td></tr>"
				else
					eval ${command} > ${prereqsDir}/${index}.prerequisite.1.txt 2> ${prereqsDir}/${index}.prerequisite.2.txt
					exitCodeGot=$?
					enddate=`date +"%Y-%m-%d %H:%M:%S"`
					time=`timeconvert "${startdate}" "${enddate}"`
					if [[ ${exitCodeGot} -eq 0 ]]
					then
						printf "%-18s: %-7s [${startdate} - ${enddate}] ${description}\n" "Pre-Requisite[${index}]" Success
						htmlPreReqs="${htmlPreReqs} <tr><td>${index}</td><td><span class=\"success\">✓</span> Success</td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td><span class=\"tooltip\">${description}<span class=\"right\">${cmd}</span></span></td></tr>"
					else
						fail="`cat ${prereqsDir}/${index}.prerequisite.2.txt`"
						fail="${fail//$'\n'/<br>}"
						fail="Exit Code: ${exitCodeGot}<br>${fail}"
						printf "%-18s: %-7s [${startdate} - ${enddate}] ${description}\n" "Pre-Requisite[${index}]" Failed
						htmlPreReqs="${htmlPreReqs} <tr><td>${index}</td><td><span class=\"failed\">✗</span> <span class=\"tooltip\"> Failed<span class=\"right\">${fail}</span></span></td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td><span class=\"tooltip\">${description}<span class=\"right\">${cmd}</span></span></td></td></tr>"
						success=1
					fi
				fi
			fi
		done
	fi
	export htmlPreReqs
	return ${success}
}

# handle all test cases
function handleTestCases() {
	if [[ -z ${cases} ]]
	then
		testCases=`jq --tab '.tests.cases' < ${file} | tr -d '\r'`
	else
		# case1,case2,case3 -> "case1","case2","case3"
		caseList="\"${cases//,/\",\"}\""
		testCases=`jq --tab '[.tests.cases[] | select(.number | IN(['"$caseList"'][]))]' < ${file} | tr -d '\r'`
	fi
	length=`echo "$testCases" | jq '. | length' | tr -d '\r'`
	sequence=`seq 0 $(( ${length} - 1 ))`
	for i in ${sequence}
	do
		index=$(( $i + 1))
		# read test case and all parameter
		testCase=`echo "$testCases" | jq '.['${i}']'| tr -d '\r'`
		number=`echo ${testCase} | jq -r '.number // empty' | tr -d '\r'`
		description=`echo ${testCase} | jq -r '.description // empty' | tr -d '\r'`
		setup=`echo ${testCase} | jq -r '.setup // empty' | tr -d '\r'`
		command=`echo ${testCase} | jq -r '.command // empty' | tr -d '\r'`
		teardown=`echo ${testCase} | jq -r '.teardown // empty' | tr -d '\r'`
		exitCode=`echo ${testCase} | jq -r '.exitCode // empty' | tr -d '\r'`
		outputPattern=`echo ${testCase} | jq -r '.outputPattern // empty' | tr -d '\r'`
		# save test case to test case directory
		echo ${testCase} > ${casesDir}/${number}.json
		totalCount=$((${totalCount} + 1))
		# timestamp
		startdate=`date +"%Y-%m-%d %H:%M:%S"`
		# if test command is empty skip this test case
		if [[ -z ${command} ]]
		then
			enddate=`date +"%Y-%m-%d %H:%M:%S"`
			time=`timeconvert "${startdate}" "${enddate}"`
			printf "%-18s: %-7s %-7s [${startdate} - ${enddate}] ${description}\n" "TestCase[${index}]" "${number}" Skipped
			htmlCases="${htmlCases} <tr><td>${index}</td><td>${number}</td><td><span class=\"skipped\">↷</span> Skipped</td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td>${description}</td></tr>"
			skippedCount=$((${skippedCount} + 1))
			continue
		fi
		# run setup command if available
		if [[ -n ${setup} ]]
		then
			setupcmd=`echo ${setup} | envsubst`
			echo ${setupcmd} > ${runsDir}/${number}.setup.command.txt
			[[ debug -eq 1 ]] && echo "TestCase[${index}]: ${number} Running Setup"
			eval "${setup}" > ${runsDir}/${number}.setup.1.txt 2> ${runsDir}/${number}.setup.2.txt
		fi
		# log and run test command
		cmd=`echo ${command} | envsubst`
		echo ${cmd} > ${runsDir}/${number}.test.command.txt
		[[ debug -eq 1 ]] && echo "TestCase[${index}]: ${number} Running Test"
		eval "${command}" > ${runsDir}/${number}.test.1.txt 2> ${runsDir}/${number}.test.2.txt
		exitCodeGot=$?
		# run teardown command if available
		if [[ -n ${teardown} ]]
		then
			teardowncmd=`echo ${teardown} | envsubst`
			echo ${teardowncmd} > ${runsDir}/${number}.teardown.command.txt
			[[ debug -eq 1 ]] && echo "TestCase[${index}]: ${number} Running Teardown"
			eval ${teardown} > ${runsDir}/${number}.teardown.1.txt 2> ${runsDir}/${number}.teardown.2.txt
		fi
		successExitCode=0
		successoutputPattern=0
		# calculate test result
		if [[ -n ${exitCode} ]]
		then
			if [[ ${exitCode} -ne ${exitCodeGot} ]]
			then
				successExitCode=1
			fi
		fi
		if [[ -n ${outputPattern} ]]
		then
			if [[ ${exitCode} -eq 0 ]]
			then
				grep -qE "${outputPattern}" ${runsDir}/${number}.test.1.txt
			else
				grep -qE "${outputPattern}" ${runsDir}/${number}.test.2.txt
			fi
			if [[ $? -ne 0 ]]
			then
				successoutputPattern=1
			fi
		fi
		enddate=`date +"%Y-%m-%d %H:%M:%S"`
		time=`timeconvert "${startdate}" "${enddate}"`
		# print test result
		if [[ ${successExitCode} -eq 0 ]] && [[ ${successoutputPattern} -eq 0 ]]
		then
			printf "%-18s: %-7s %-7s [${startdate} - ${enddate}] ${description}\n" "TestCase[${index}]" "${number}" Success
			success="stdout: `cat ${runsDir}/${number}.test.1.txt`"
			htmlCases="${htmlCases} <tr><td>${index}</td><td><span class="tooltip">${number}<span class="right">${testCase}</span></span></td><td><span class=\"tooltip\"><span class=\"success\">✓</span> Success<span class=\"right\">${success}</span></span></td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td><span class=\"tooltip\">${description} <span class=\"right\">${cmd}</span></span></td></tr>"
			successCount=$((${successCount} + 1))
		else
			printf "%-18s: %-7s %-7s [${startdate} - ${enddate}] ${description}\n" "TestCase[${index}]" "${number}" Failed
			# https://gist.github.com/JPvRiel/b337dfee8f273aac1332447ed1342304
			# https://www.codeply.com/p/C8083WXo5Z
			fail="stderr: `cat ${runsDir}/${number}.test.2.txt`"
			fail="${fail//$'\n'/<br>}"
			fail="${fail}<br>exit-code: ${exitCodeGot}"
			htmlCases="${htmlCases} <tr><td>${index}</td><td><span class="tooltip">${number}<span class="right">${testCase}</span></span></td><td><span class=\"tooltip\"><span class=\"failed\">✗</span> Failed<span class=\"right\">${fail}</span></span></td><td><span class=\"tooltip\">${startdate} - ${enddate}<span class=\"right\">${time}</span></span></td><td><span class=\"tooltip\">${description} <span class=\"right\">${cmd}</span></span></td></tr>"
			failedCount=$((${failedCount} + 1))
		fi
	done
	export htmlCases
}

# create report summary
function createSummary() {
	echo "Test Summary"
	echo "Skipped tests = ${skippedCount}"
	echo "Failed tests = ${failedCount}"
	echo "Successful tests = ${successCount}"
	echo "------------------------------------"
	echo "Total tests = ${totalCount}"
	echo
	echo "Start Time ... ${testStart}"
	echo "End Time ..... ${testEnd}"
	echo "Duration ..... ${duration}"
}

# create html report
function createHtml() {
	# https://freefrontend.com/css-tree-view/
	# https://codepen.io/johnbarnitz/pen/gOPbVer
	# http://www.menucool.com/tooltip/css-tooltip
	# https://stackoverflow.com/questions/18517483/displaying-long-text-in-bootstrap-tooltip
	envsubst < template.report.html > ${currDir}/report.html
	cp -r resources/ ${currDir}
}

# zip reports
function createZip() {
	zip -qr ${zipDir}/${testStart}.zip ${currDir}
	rm -rf ${lastDir}
	mv ${currDir} ${lastDir}
}

# run all test parts
function doall() {
	checkjq
	export totalCount=0
	export skippedCount=0
	export successCount=0
	export failedCount=0
	echo "Date of Test Run:  ${testStart}"
	echo "_____________________________________________________________________________________________________________________"
	handleVars
	handlePreReqs
	error=$?
	echo "_____________________________________________________________________________________________________________________"
	if [[ ${error} -ne 0 ]]
	then
		echo "Aborted: Prerequistes failed"
		export htmlFailed="<h2 class=\"failed\">Aborted: Prerequistes failed</h2>"
	else
		handleTestCases
	fi
	echo "_____________________________________________________________________________________________________________________"
	export testEnd=`date +"%Y-%m-%d-%H-%M-%S"`
	export testEndSeconds=`date +"%s"`
	secs=$((testEndSeconds-testStartSeconds))
	export duration=`printf '%d %02d:%02d:%02d\n' $((secs/86400)) $((secs%86400/3600)) $((secs%3600/60)) $((secs%60))`
	createSummary
	createHtml
	createZip
}

##################
# main starts here
##################

skipPrerequisites=0
debug=0
while getopts ":c:f:pvx" opt
do
	case ${opt} in
	c)
		# from https://stackoverflow.com/questions/10586153/how-to-split-a-string-into-an-array-in-bash
		cases="${OPTARG}"
		;;
	f)
		file=${OPTARG}
		;;
	p)
		skipPrerequisites=1
		;;
	v)
		debug=1
		;;
	x)
		set -x
		;;
	\?)
		echo "Error: Unknown option ${OPTARG}"
		echo
		printhelp
		;;
	esac
done

# check arguments, file (-f) is required
shift $((OPTIND-1))
if [[ $# -ne 0 || -z "${file:-}" ]]
then
	printhelp
fi

# get date and time stamp
export testStart=`date +"%Y-%m-%d-%H-%M-%S"`
export testStartSeconds=`date +"%s"`

# create report directories
reportsDir=reports
lastDir=${reportsDir}/latest
currDir=${reportsDir}/${testStart}
zipDir=${reportsDir}/zip
logfile=${currDir}/report.txt
casesDir=${currDir}/cases
prereqsDir=${currDir}/prereqs
runsDir=${currDir}/runs
for dir in ${casesDir} ${prereqsDir} ${runsDir}
do
	rm -rf ${dir}
	mkdir -p ${dir}
done
mkdir -p ${zipDir}

# invoke main function
{
	doall
} 2>&1 | tee ${logfile}
