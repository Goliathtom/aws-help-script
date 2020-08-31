#!/usr/bin/env bash

set -e

# Variables
export DOCKER_TAG=${DOCKER_TAG}

COMMAND=${1}
CLUSTER_NAME=''
SERVICE_NAME=''
DOCKER_TAG=''
COMPOSE_FILE_DIR=''
TARGET_GROUP_NAME=''
DESIRED_COUNT=0
LAUNCH_TYPE=''
COMPOSE_BASE_FILE_DIR=''
CLUSTER_REGION=''
PROFILE=''

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
            --docker-tag)
                DOCKER_TAG="$2"
                shift 2
                ;;
            --compose-file-dir)
                COMPOSE_FILE_DIR="$2"
                shift 2
                ;;
            --base-file)
                COMPOSE_BASE_FILE_DIR="$2"
                shift 2
                ;;
            --target-group)
                TARGET_GROUP_NAME="$2"
                shift 2
                ;;
            --count)
                DESIRED_COUNT="$2"
                shift 2
                ;;
            --launch-type)
                LAUNCH_TYPE="$2"
                shift 2
                ;;
            --region)
                CLUSTER_REGION="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
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

    if [[ -z "${CLUSTER_NAME}" || -z "${SERVICE_NAME}" ]] 
    then
        print_usage
        exit 1
    fi

    if [[ -z "${COMPOSE_FILE_DIR}" ]]
    then
        print_error_compose_file
        exit 1
    fi

    if [[ -z ${LAUNCH_TYPE} ]] 
    then
        echo "Set Launch Type to the default <EC2>"
        LAUNCH_TYPE="EC2"
    fi

    if [[ -z ${CLUSTER_REGION} ]] 
    then
        CLUSTER_REGION="ap-northeast-2"
        echo "Set Region to the default <ap-northeast-2>"
    fi

    if [[ -z ${PROFILE} ]] 
    then
        PROFILE="default"
        echo "Set profile to the default"
    fi
}

function print_usage
{
    echo
    echo "Usage: ecs_service.sh <command> <params...>"
    echo
    echo "Commands:"
    echo "  create      Create ECS service"
    echo "  scale       Scale ECS service up/down"
    echo "  update      Update ECS service"
    echo "  delete      Delete ECS service"
    echo
    echo "Examples:"
    echo "  ecs_service.sh create --cluster {CLUSTER_NAME} --service {SERVICE_NAME} --docker-tag {DOCKER_TAG} --compose-file-dir {COMPOSE_FILE_SRC} --target-group (target_group_name)"
    echo "  ecs_service.sh scale --cluster {CLUSTER_NAME} --service {SERVICE_NAME} --count 4 --compose-file-dir {COMPOSE_FILE_SRC}"
    echo "  ecs_service.sh update --cluster {CLUSTER_NAME} --service {SERVICE_NAME} --docker-tag {DOCKER_TAG} --compose-file-dir {COMPOSE_FILE_SRC} --launch-type (EC2|FARGATE)"
    echo "  ecs_service.sh delete --cluster {CLUSTER_NAME} --service {SERVICE_NAME} --compose-file-dir {COMPOSE_FILE_SRC}"
}

function print_error_compose_file
{
    echo "Can't find compose file dir. need to add option: --compose-file-dir"
    echo "Example:"
    echo "  --compose-file-dir projects/cms/admin"
    echo "  Or"
    echo "  --compose-file-dir cms/admin"
    echo "  (You can except the path 'projects/')"
}

function create_service
{
    set_params "$@"
    local compose_file_dir=${COMPOSE_FILE_DIR}
    local target_group_name=${TARGET_GROUP_NAME}

    if [[ compose_file_dir != *"projects/"* ]]
    then
        compose_file_dir="projects/${compose_file_dir}"
    fi

    if [[ -z "${DOCKER_TAG}" ]]
    then
        echo "docker_tag is undefined. Creating service is failed."
        print_usage
        exit 1
    else
        export DOCKER_TAG=${DOCKER_TAG}
    fi

    if [[ -z "${target_group_name}" ]]
    then
        target_group_name=ecs-${SERVICE_NAME}
    fi

    echo "Start creating service name='${SERVICE_NAME}'..."

    echo "Search service name='${SERVICE_NAME}'..."
    local service_status=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" | jq -r ".services[0].status")
    if [[ ${service_status} == "ACTIVE" ]]
    then
        echo "A service name='${SERVICE_NAME}' already exists. Skip creating service!"
        echo
        return
    fi

    echo "Search target_group name=${target_group_name}.."
    local target_group_arn=$(aws elbv2 describe-target-groups | jq -r ".TargetGroups[] | select(.TargetGroupName == \"${target_group_name}\") | .TargetGroupArn")
    if [[ -z ${target_group_arn} ]]
    then
        echo "A target_group name='${target_group_name}' doesn't exists."
        echo "Skip to connect with target group..."
    fi

    echo
    echo "- region=${CLUSTER_REGION}"
    echo "- cluster name=${CLUSTER_NAME}"
    echo "- compose file dir=${compose_file_dir}"
    if ! [[ -z ${target_group_arn} ]]
    then
        echo "- target_group arn=${target_group_arn}"
        echo "- health-check-grace-period=${SERVICE_HEALTHCHECK_GRACE_PERIOD}"
    fi
    echo "- container-name=${TARGET_GROUP_CONTAINER_NAME}"
    echo "- container-port=${TARGET_GROUP_CONTAINER_PORT}"
    echo "- deployment-min-healthy-percent=${SERVICE_DEPLOY_MIN_PERCENT}"
    echo "- deployment-max-percent=${SERVICE_DEPLOY_MAX_PERCENT}"
    echo "Create service name='${SERVICE_NAME}' tag='${DOCKER_TAG}'..."

    if ! [[ -z ${target_group_arn} ]]
    then
        create_service_with_tg ${CLUSTER_NAME} ${SERVICE_NAME} ${target_group_arn} ${compose_file_dir}
    else
        create_service_without_tg ${CLUSTER_NAME} ${SERVICE_NAME} ${compose_file_dir}
    fi

    echo "Complete creating service!"
    echo
}

function create_service_with_tg
{
    local cluster_name=${1}
    local service_name=${2}
    local target_group_arn=${3}
    local compose_file_dir=${4}
    local tags=${5}

    ecs-cli compose \
        --project-name ${service_name} \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        create \
        --launch-type EC2

    echo "1. Complete creating task-definition"

    if [[ ${CLUSTER_NAME} == 'test-site' ]]
    then
       timestamp=$(TZ=Asia/Seoul date +"%Y-%m-%d-%H:%M:%S")
       tags=("key=origin-ref,value=${ORIGIN_REF} key=timestamp,value=${timestamp} key=php-src-ref,value=${PHP_SRC_REF}")
    fi

    # create to set placement-strategy of service
    ### Because DO NOT support it on ecs-cli
    aws ecs create-service \
        --cluster ${CLUSTER_NAME} \
        --service-name ${service_name} \
        --task-definition ${service_name} \
        --desired-count 1 \
        --load-balancers targetGroupArn=${target_group_arn},containerName=${TARGET_GROUP_CONTAINER_NAME},containerPort=${TARGET_GROUP_CONTAINER_PORT} \
        --placement-strategy type=binpack,field=cpu \
        --tags ${tags}

    echo "2. Complete creating service"

    ecs-cli compose \
        --project-name ${service_name} \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        service up \
        --region ${CLUSTER_REGION} \
        --cluster ${CLUSTER_NAME} \
        --container-name ${TARGET_GROUP_CONTAINER_NAME} \
        --container-port ${TARGET_GROUP_CONTAINER_PORT} \
        --deployment-min-healthy-percent ${SERVICE_DEPLOY_MIN_PERCENT} \
        --deployment-max-percent ${SERVICE_DEPLOY_MAX_PERCENT} \
        --target-group-arn ${target_group_arn} \
        --health-check-grace-period ${SERVICE_HEALTHCHECK_GRACE_PERIOD} \
        --role ecsServiceRole \
        --create-log-groups

    echo "3. Complete up service"
}

function create_service_without_tg
{
    local cluster_name=${1}
    local service_name=${2}
    local compose_file_dir=${3}

    # create to set placement-strategy of service
    ### Because DO NOT support it on ecs-cli
    aws ecs create-service \
        --cluster ${cluster_name} \
        --service-name ${service_name} \
        --task-definition ${service_name} \
        --desired-count 1 \
        --placement-strategy type=binpack,field=cpu

    ecs-cli compose \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        --project-name ${service_name} \
    service up \
        --region ${CLUSTER_REGION} \
        --cluster ${cluster_name} \
        --deployment-min-healthy-percent ${SERVICE_DEPLOY_MIN_PERCENT} \
        --deployment-max-percent ${SERVICE_DEPLOY_MAX_PERCENT} \
        --create-log-groups
}

function scale_service
{
    set_params "$@"
    local compose_file_dir=${COMPOSE_FILE_DIR}

    if [[ -z "${DESIRED_COUNT}" ]]
    then
        print_usage
        exit 1
    fi

    if [[ compose_file_dir != *"projects/"* ]]
    then
        compose_file_dir="projects/${compose_file_dir}"
    fi

    echo "Start scaling service name=${SERVICE_NAME} to ${DESIRED_COUNT}..."

    echo "Search service_desired_count name='${SERVICE_NAME}'..."
    local service_desired_count=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" | jq -r ".services[0] | .desiredCount")
    if [[ ${service_desired_count} == "${DESIRED_COUNT}" ]]
    then
        echo "The desired count of service name='${SERVICE_NAME}' is already ${DESIRED_COUNT}. Skip scaling service!"
        echo
        return
    fi

    echo
    echo "- region=${CLUSTER_REGION}"
    echo "- cluster name=${CLUSTER_NAME}"
    echo "- compose file dir=${compose_file_dir}"
    echo "- desired_count=${DESIRED_COUNT}"
    echo "Scale service name=${SERVICE_NAME} to ${DESIRED_COUNT}..."

    ecs-cli compose \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        --project-name ${SERVICE_NAME} \
    service scale \
        --region ${CLUSTER_REGION} \
        --cluster ${CLUSTER_NAME} \
    ${DESIRED_COUNT}

    echo "Complete scaling service!"
    echo
}

function update_service
{
    set_params "$@"
    local compose_file_dir=${COMPOSE_FILE_DIR}

    if [[ compose_file_dir != *"projects/"* ]]
    then
        compose_file_dir="projects/${compose_file_dir}"
    fi

    if [[ -z "${DOCKER_TAG}" ]]
    then
        echo "docker_tag is undefined. Updating service is failed."
        print_usage
        exit 1
    else
        export DOCKER_TAG=${DOCKER_TAG}
    fi

    echo "Start Updating service name='${SERVICE_NAME}'..."
    echo
    echo "- region=${CLUSTER_REGION}"
    echo "- cluster name=${CLUSTER_NAME}"
    echo "- compose file dir=${compose_file_dir}"
    echo "- image tag=${DOCKER_TAG}"
    echo "- Service Launch Type=${LAUNCH_TYPE}"
    echo "Update service name='${SERVICE_NAME}' tag='${DOCKER_TAG}'..."

    ecs_base_command=""
    if [[ -e "${COMPOSE_BASE_FILE_DIR}" ]]
    then
      ecs_base_command="--file ${COMPOSE_BASE_FILE_DIR}"
      echo "Base docker-compose: ${COMPOSE_BASE_FILE_DIR}"
    else
      ecs_base_path="${COMPOSE_BASE_FILE_DIR}/docker-compose.yml"
      if [[ -e "${ecs_base_path}" ]]
      then
        ecs_base_command="--file ${ecs_base_path}"
        echo "Base docker-compose: ${ecs_base_path}"
      fi
    fi

    ecs-cli compose \
        ${ecs_base_command} \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        --project-name ${SERVICE_NAME} \
    service up \
        --region ${CLUSTER_REGION} \
        --cluster ${CLUSTER_NAME} \
        --launch-type ${LAUNCH_TYPE} \
        --timeout 20 \
        --create-log-groups

    echo "Complete updating service!"
    echo
}

function delete_service
{
    set_params "$@"
    local compose_file_dir=${COMPOSE_FILE_DIR}

    if [[ compose_file_dir != *"projects/"* ]]
    then
        compose_file_dir="projects/${compose_file_dir}"
    fi

    echo "Start deleting service name=${SERVICE_NAME}..."

    echo "Search service name='${SERVICE_NAME}'..."
    local service_count=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" | jq -r ".services | length")
    if [[ ${service_count} == "0" ]]
    then
        echo "A service name='${SERVICE_NAME}' doesn't exists. Skip deleting service!"
        echo
        return
    fi

    echo
    echo "- region=${CLUSTER_REGION}"
    echo "- cluster name=${CLUSTER_NAME}"
    echo "- compose file dir=${compose_file_dir}"
    echo "Delete service name=${SERVICE_NAME}..."

    ecs-cli compose \
        --file ${compose_file_dir}/docker-compose.yml \
        --ecs-params ${compose_file_dir}/ecs-params.yml \
        --project-name ${SERVICE_NAME} \
    service rm \
        --region ${CLUSTER_REGION} \
        --cluster ${CLUSTER_NAME} \
        --timeout 10

    echo "Complete deleting service!"
    echo
}


if [[ ( ${COMMAND} == "create" && ${#} -lt 4 ) \
   || ( ${COMMAND} == "scale" && ${#} -lt 4 ) \
   || ( ${COMMAND} == "update" && ${#} -lt 4 ) \
   || ( ${COMMAND} == "delete" && ${#} -lt 3 ) ]]
then
    print_usage
    exit 1
fi


if [[ ${COMMAND} == "create" ]]; then create_service "$@"
elif [[ ${COMMAND} == "scale" ]]; then scale_service "$@"
elif [[ ${COMMAND} == "update" ]]; then update_service "$@"
elif [[ ${COMMAND} == "delete" ]]; then delete_service "$@"
else
    echo "${COMMAND} is undefined."
    print_usage
    exit 1
fi
