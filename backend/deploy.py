import os
import shutil
import sys
import zipfile
import subprocess

LAMBDA_IMAGE = "public.ecr.aws/lambda/python:3.12"
DOCKER_PLATFORM = "linux/amd64"

def safe_rmtree(path):
    """Remove a directory even if Docker created root-owned files."""
    if not os.path.exists(path):
        return
    try:
        shutil.rmtree(path)
        return
    except PermissionError:
        print(f"Permission issue removing {path}, retrying via Docker...")
        try:
            subprocess.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{os.getcwd()}:/var/task",
                    "--platform",
                    DOCKER_PLATFORM,
                    "--entrypoint",
                    "/bin/sh",
                    LAMBDA_IMAGE,
                    "-c",
                    f"rm -rf /var/task/{path}",
                ],
                check=True,
            )
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            raise PermissionError(
                f"Failed to remove {path}. Try `sudo rm -rf {os.path.join(os.getcwd(), path)}` or ensure Docker access."
            ) from exc
        if os.path.exists(path):
            raise

def install_dependencies(target_dir):
    print("Installing dependencies for lambda runtime...")

    user_args = []
    if hasattr(os, "getuid") and hasattr(os, "getgid"):
        user_args = ["-u", f"{os.getuid()}:{os.getgid()}"]

    docker_cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{os.getcwd()}:/var/task",
        "--platform",
        DOCKER_PLATFORM,
        "--entrypoint",
        "", #override default entry point, so how we execute?
        *user_args,
        LAMBDA_IMAGE,
        "/bin/sh",
        "-c",
        "pip install --target /var/task/lambda-package -r /var/task/requirements.txt --platform manylinux2014_x86_64 --only-binary=:all: --upgrade",
    ]

    try:
        subprocess.run(docker_cmd, check=True)
        return
    except FileNotFoundError:
        print("Docker not available; falling back to local pip install...")
    except subprocess.CalledProcessError:
        print("Docker install failed (permissions?). Falling back to local pip install...")

    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--target",
            target_dir,
            "-r",
            "requirements.txt",
            "--upgrade",
        ],
        check=True,
    )

def main():
    print("creating lambda deployment package...")

    #clean up
    safe_rmtree("lambda-package")
    if os.path.exists("lambda-deployment.zip"):
        os.remove("lambda-deployment.zip")

    #create package directory
    os.makedirs("lambda-package", exist_ok=True)

    # Install dependencies using Docker with lambda runtime image
    install_dependencies("lambda-package")

    #copy application files
    print("Copying application files...")
    for file in ["server.py", "lambda_handler.py", "context.py", "resources.py"]:
        if os.path.exists(file):
            shutil.copy2(file, "lambda-package/")
    
    # Copy data directory
    if os.path.exists("data"):
        shutil.copytree("data", "lambda-package/data")

    # Create zip
    print("Creating zip file...")
    with zipfile.ZipFile("lambda-deployment.zip", "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk("lambda-package"):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, "lambda-package")
                zipf.write(file_path, arcname)

    # Show package size
    size_mb = os.path.getsize("lambda-deployment.zip") / (1024 * 1024)
    print(f"✓ Created lambda-deployment.zip ({size_mb:.2f} MB)")

if __name__ == "__main__":
    main()
