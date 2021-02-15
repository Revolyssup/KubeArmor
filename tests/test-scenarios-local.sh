#!/bin/bash

TEST_HOME=`dirname $(realpath "$0")`
CRD_HOME=`dirname $(realpath "$0")`/../deployments/CRD
ARMOR_HOME=`dirname $(realpath "$0")`/../KubeArmor

ARMOR_MSG=$TEST_HOME/message.log
ARMOR_LOG=$TEST_HOME/kubearmor.log

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

YES=$1

if [ ! -z $1 ]; then
    if [ "$YES" != "-y" ]; then
        echo "Usage: $0 [-y]"
        echo "Options:"
        echo "  -y => automatically clean logs up"
        exit
    fi
fi

## == Functions == ##

function start_and_wait_for_kubearmor_initialization() {
    cd $CRD_HOME

    kubectl apply -f .
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to apply $1${NC}"
        exit 1
    fi

    PROXY=$(ps -ef | grep "kubectl proxy" | wc -l)
    if [ $PROXY != 2 ]; then
        echo -e "${RED}[FAIL] Proxy is not running${NC}"
        exit 1
    fi

    cd $ARMOR_HOME

    sudo -E ./kubearmor -output=$ARMOR_LOG > $ARMOR_MSG &

    for (( ; ; ))
    do
        grep "Initialized KubeArmor" $ARMOR_MSG &> /dev/null
        if [ $? == 0 ]; then
            break
        fi

        sleep 1
    done
}

function stop_and_wait_for_kubearmor_termination() {
    ps -e | grep kubearmor | awk '{print $1}' | xargs -I {} sudo kill {}

    for (( ; ; ))
    do
        ps -e | grep kubearmor &> /dev/null
        if [ $? != 0 ]; then
            break
        fi

        sleep 1
    done
}

function apply_and_wait_for_microservice_creation() {
    cd $TEST_HOME/microservices/$1

    kubectl apply -f .
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to apply $1${NC}"
        res_microservice=1
        return
    fi

    for (( ; ; ))
    do
        RAW=$(kubectl get pods -n $1 | wc -l)

        ALL=`expr $RAW - 1`
        READY=`kubectl get pods -n $1 | grep Running | wc -l`

        if [ $ALL == $READY ]; then
            break
        fi

        sleep 1
    done
}

function delete_and_wait_for_microserivce_deletion() {
    cd $TEST_HOME/microservices/$1

    kubectl delete -f .
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to delete $1${NC}"
        res_delete=1
    fi
}

function find_allow_logs() {
    echo -e "${GREEN}[INFO] Finding the corresponding log${NC}"

    sleep 1

    grep PolicyMatched $ARMOR_LOG | tail -n 10 $ARMOR_LOG | grep $1 | grep $2 | grep $3 | grep $4 | grep Passed
    if [ $? == 0 ]; then
        echo -e "${RED}[FAIL] Found the log from logs${NC}"
        res_cmd=1
    else
        echo "[INFO] Found no log from logs"
    fi
}

function find_audit_logs() {
    echo -e "${GREEN}[INFO] Finding the corresponding log${NC}"

    sleep 1

    grep PolicyMatched $ARMOR_LOG | tail -n 10 $ARMOR_LOG | grep $1 | grep $2 | grep $3 | grep $4 | grep Passed
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to find the log from logs${NC}"
        res_cmd=1
    else
        echo "[INFO] Found the log from logs"
    fi
}

function find_block_logs() {
    echo -e "${GREEN}[INFO] Finding the corresponding log${NC}"

    sleep 1

    grep PolicyMatched $ARMOR_LOG | tail -n 10 $ARMOR_LOG | grep $1 | grep $2 | grep $3 | grep $4 | grep -v Passed
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to find the log from logs${NC}"
        res_cmd=1
    else
        echo "[INFO] Found the log from logs"
    fi
}

function run_test_scenario() {
    cd $1

    YAML_FILE=$(ls *.yaml)

    echo -e "${GREEN}[INFO] Applying $YAML_FILE into $2${NC}"
    kubectl apply -n $2 -f $YAML_FILE
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to apply $YAML_FILE into $2${NC}"
        res_case=1
        return
    fi
    echo "[INFO] Applied $YAML_FILE into $2"

    sleep 2

    for cmd in $(ls cmd*)
    do
        SOURCE=$(cat $cmd | grep source | awk '{print $2}')
        POD=$(kubectl get pods -n $2 | grep $SOURCE | awk '{print $1}')

        CMD=$(cat $cmd | grep cmd | cut -d' ' -f2-)
        RESULT=$(cat $cmd | grep result | awk '{print $2}')

        OP=$(cat $cmd | grep operation | awk '{print $2}')
        COND=$(cat $cmd | grep condition | cut -d' ' -f2-)
        ACTION=$(cat $cmd | grep action | awk '{print $2}')

        res_cmd=0

        echo -e "${GREEN}[INFO] Running \"$CMD\"${NC}"
        kubectl exec -n $2 -it $POD -- bash -c "$CMD"
        if [ $? == 0 ]; then
            if [ "$ACTION" == "Allow" ] && [ "$RESULT" == "passed" ]; then
                find_allow_logs $POD $OP $COND $ACTION
            elif [ "$ACTION" == "AllowWithAudit" ] && [ "$RESULT" == "passed" ]; then
                find_audit_logs $POD $OP $COND $ACTION
            elif [ "$ACTION" == "Audit" ] && [ "$RESULT" == "audited" ]; then
                find_audit_logs $POD $OP $COND $ACTION
            elif [ "$RESULT" == "failed" ]; then
                echo -e "${MAGENTA}[WARN] Expected failure, but got success${NC}"
            fi
        else
            if [ "$RESULT" == "failed" ]; then
                find_block_logs $POD $OP $COND $ACTION
            else
                echo -e "${MAGENTA}[WARN] Expected success, but got failure${NC}"
            fi
        fi

        if [ $res_cmd != 0 ]; then
            break
        fi

        sleep 1
    done

    if [ $res_cmd != 0 ]; then
        echo -e "${RED}[FAIL] Failed $3${NC}"
        res_case=1
    else
        echo -e "${BLUE}[PASS] Passed $3${NC}"
    fi

    echo -e "${GREEN}[INFO] Deleting $YAML_FILE from $2${NC}"
    kubectl delete -n $2 -f $YAML_FILE
    if [ $? != 0 ]; then
        echo -e "${RED}[FAIL] Failed to delete $YAML_FILE from $2${NC}"
        res_case=1
        return
    fi
    echo "[INFO] Deleted $YAML_FILE from $2"

    sleep 1
}

## == KubeArmor == ##

cd $ARMOR_HOME

if [ ! -f kubearmor ]; then
    echo -e "${ORANGE}[INFO] Building KubeArmor${NC}"
    make clean; make
    echo "[INFO] Built KubeArmor"
fi

sudo rm -f $ARMOR_MSG $ARMOR_LOG

sleep 1

echo -e "${ORANGE}[INFO] Starting KubeArmor${NC}"
start_and_wait_for_kubearmor_initialization
echo "[INFO] Started KubeArmor"

## == Test Scenarios == ##

cd $TEST_HOME

res_microservice=0

for microservice in $(ls microservices)
do
    ## == ##

    echo -e "${ORANGE}[INFO] Applying $microservice${NC}"
    apply_and_wait_for_microservice_creation $microservice

    ## == ##

    if [ $res_microservice == 0 ]; then
        echo "[INFO] Applied $microservice"

        echo "[INFO] Wait for initialization"
        sleep 30
        echo "[INFO] Started to run testcases"

        cd $TEST_HOME/scenarios

        for testcase in $(ls -d $microservice_*)
        do
            res_case=0

            echo -e "${ORANGE}[INFO] Testing $testcase${NC}"
            run_test_scenario $TEST_HOME/scenarios/$testcase $microservice $testcase

            if [ $res_case != 0 ]; then
                res_microservice=1
                break
            fi

            echo "[INFO] Tested $testcase"
        done

        res_delete=0

        echo -e "${ORANGE}[INFO] Deleting $microservice${NC}"
        delete_and_wait_for_microserivce_deletion $microservice

        if [ $res_delete == 0 ]; then
            echo "[INFO] Deleted $microservice"
        fi
    fi

    ## == ##

    if [ $res_microservice != 0 ]; then
        break
    fi

    ## == ##
done

## == KubeArmor == ##

res_kubearmor=0

echo -e "${ORANGE}[INFO] Stopping KubeArmor${NC}"
stop_and_wait_for_kubearmor_termination

if [ $res_kubearmor == 0 ]; then
    echo "[INFO] Stopped KubeArmor"
fi

if [ $res_microservice != 0 ]; then
    echo -e "${RED}[FAIL] Failed to test KubeArmor${NC}"
else
    echo -e "${BLUE}[PASS] Successfully tested KubeArmor${NC}"
fi

if [ "$YES" == "-y" ]; then
    sudo rm -f $ARMOR_MSG $ARMOR_LOG
else
    while true;
    do
        read -p "Do you want to delete log files (Yn)?" yn
        case $yn in
            [Nn]*) break;;
            *) sudo rm -f $ARMOR_MSG $ARMOR_LOG; break;;
        esac
    done
fi

if [ $res_microservice != 0 ]; then
    exit 1
else
    exit 0
fi
