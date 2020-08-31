#!/usr/bin/env bash

set -e

COMMAND=${1}
CLUSTER_NAME=''
SERVICE_NAME=''

function set_params {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            --help)
                print_usage
                exit 0
                ;;
            -*)
                echo "Unrecognized argument: $1"
                print_usage
                exit 1
                ;;
            *)
                shift
                ;;
        esac
    done
}

function print_usage
{
    echo
    echo "Usage: ecs_scheduled_task.sh <command> <cluster-name> <task-definition-name>"
    echo
    echo "Commands:"
    #echo "  create      Create ECS Scheduled Task"
    echo "  update      Update ECS Scheduled Task"
    #echo "  delete      Delete ECS Scheduled Task"
    echo
    echo "Examples:"
    #echo "  ecs_scheduled_task.sh create platform-dev book-api"
    echo "  ecs_scheduled_task.sh update platform-dev book-api"
    #echo "  ecs_scheduled_task.sh delete platform-dev book-api"
}

function update_tasks
{
    set_params "$@"
    local cluster_arn=$(aws ecs list-clusters | jq -r ".clusterArns[]" | grep "${CLUSTER_NAME}")

    if [[ -z cluster_arn ]]
    then
        echo "${CLUSTER_NAME} is undefined..."
        exit 1
    fi

    local scheduled_tasks_in_ecs=$(aws events list-rule-names-by-target --target-arn "${cluster_arn}" | jq -r ".RuleNames[]")

    echo "${scheduled_tasks_in_ecs[*]}"
    for rule in ${scheduled_tasks_in_ecs[@]}; do
        echo "Rule : ${rule}"
        local json_target=$(aws events list-targets-by-rule --rule "${rule}" \
            | jq -r ".Targets[] | select(.Arn == \"${cluster_arn}\")")
        local current_task_definition_arn=$(echo "${json_target}" | jq -r ".EcsParameters | .TaskDefinitionArn")
        local family_name_from_task_definition=$(echo "${current_task_definition_arn}" | cut -d/ -f2 | cut -d: -f1)

        if [[ ${SERVICE_NAME} != ${family_name_from_task_definition} ]]
        then
            echo "${rule} is different Family with ${SERVICE_NAME}, so skip..."
            continue
        fi

        local last_task_definition_arn=$(aws ecs list-task-definitions --family-prefix ${SERVICE_NAME} | jq -r ".taskDefinitionArns[-1]")

        echo "================================================"
        echo "Task JSON : ${json_target}"
        echo "Current Task Definition : ${current_task_definition_arn}"
        echo "Latest Task Definition : ${last_task_definition_arn}"
        echo "================================================"

        local post_json_target=$(echo "${json_target}" | jq -r ".EcsParameters.TaskDefinitionArn=\"${last_task_definition_arn}\"")
        echo "Changed Task JSON : ${post_json_target}"

        local result=$(aws events put-targets --rule "${rule}" --targets "[${post_json_target}]" | jq -r ".")
        if [[ -z $(echo "${result}" | jq -r ".FailedEntries[]") ]]
        then
            echo "Success to Update Scheduled Task : ${rule}"
        fi
        
    done
}

#if [[ ${COMMAND} == "create" ]]; then create
#elif [[ ${COMMAND} == "update" ]]; then update
#elif [[ ${COMMAND} == "delete" ]]; then delete
if [[ ${COMMAND} == "update" ]]; then update_tasks "$@"
else
    echo "${COMMAND} is undefined."
    print_usage
    exit 1
fi