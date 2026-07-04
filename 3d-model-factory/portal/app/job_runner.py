from datetime import datetime

from kubernetes import client


def create_blender_job(
    product_id: str,
    product_md_path: str,
    output_dir: str,
    image: str,
    namespace: str = "model-factory",
    use_gpu: bool = False,
    gpu_task: str = "none",
    run_number: int | None = None,
    trigger: str = "create",
    pvc_name: str = "model-factory-pvc",
) -> str:
    batch = client.BatchV1Api()

    safe_id = product_id.replace("-", "")[:16]
    suffix = datetime.utcnow().strftime("%H%M%S")
    job_name = f"model-factory-{safe_id}-{suffix}"

    container = client.V1Container(
        name="blender-worker",
        image=image,
        image_pull_policy="Always",
        resources=client.V1ResourceRequirements(
            requests={"cpu": "1", "memory": "2Gi"},
            limits=({"cpu": "4", "memory": "8Gi", "nvidia.com/gpu": "1"} if use_gpu else {"cpu": "4", "memory": "8Gi"}),
        ),
        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=product_md_path),
            client.V1EnvVar(name="OUTPUT_DIR", value=output_dir),
            client.V1EnvVar(name="RUN_NUMBER", value=str(run_number)),
            client.V1EnvVar(name="WORKER_IMAGE", value=image),
            client.V1EnvVar(name="USE_GPU", value="true" if use_gpu else "false"),
            client.V1EnvVar(name="GPU_TASK", value=gpu_task or "none"),
        ],
        volume_mounts=[
            client.V1VolumeMount(name="model-storage", mount_path="/data")
        ],
    )

    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=pvc_name),
    )

    tolerations = []
    if use_gpu:
        tolerations = [
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx4060",
                effect="NoSchedule",
            ),
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx2070",
                effect="NoSchedule",
            ),
        ]

    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
        tolerations=tolerations,
    )

    template = client.V1PodTemplateSpec(
        metadata=client.V1ObjectMeta(labels={"app": "model-factory-worker", "product-id": product_id}),
        spec=pod_spec,
    )

    job_spec = client.V1JobSpec(
        template=template,
        backoff_limit=1,
        ttl_seconds_after_finished=86400,
    )

    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(name=job_name, namespace=namespace),
        spec=job_spec,
    )

    batch.create_namespaced_job(namespace=namespace, body=job)
    return job_name
