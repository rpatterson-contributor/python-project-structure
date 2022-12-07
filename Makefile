## Development, build and maintenance tasks

### Defensive settings for make:
#     https://tech.davis-hansson.com/p/make/
SHELL:=bash
.ONESHELL:
.SHELLFLAGS:=-eu -o pipefail -c
.SILENT:
.DELETE_ON_ERROR:
MAKEFLAGS+=--warn-undefined-variables
MAKEFLAGS+=--no-builtin-rules
PS1?=$$

# Project-specific variables
VCS_REMOTE_AUTH=
GPG_SIGNING_KEYID=2EFF7CCE6828E359
CODECOV_TOKEN=

# Values derived from the environment
USER_NAME:=$(shell id -u -n)
USER_FULL_NAME=$(shell getent passwd "$(USER_NAME)" | cut -d ":" -f 5 | cut -d "," -f 1)
ifeq ($(USER_FULL_NAME),)
USER_FULL_NAME=$(USER_NAME)
endif
USER_EMAIL=$(USER_NAME)@$(shell hostname -f)
PUID:=$(shell id -u)
PGID:=$(shell id -g)
# OS Detection
UNAME_KERNEL_NAME:=$(shell uname)
OS_ALPINE_VERSION:=$(shell cat "/etc/alpine-release" 2>"/dev/null")

# Options controlling behavior
ifeq ($(GITLAB_CI),true)
VCS_BRANCH=$(CI_COMMIT_REF_NAME)
else ifeq ($(GITHUB_ACTIONS),true)
VCS_BRANCH=$(GITHUB_REF_NAME)
else
VCS_BRANCH:=$(shell git branch --show-current)
endif
# Only publish releases from the `master` or `develop` branches
RELEASE_PUBLISH=false
TOWNCRIER_COMPARE_BRANCH=develop
PYPI_REPO=testpypi
DOCKER_PUSH=false
CI=false
GITLAB_CI=false
GITHUB_RELEASE_ARGS=--prerelease
ifeq ($(GITLAB_CI),true)
ifeq ($(VCS_BRANCH),master)
RELEASE_PUBLISH=true
TOWNCRIER_COMPARE_BRANCH=master
PYPI_REPO=pypi
DOCKER_PUSH=true
GITHUB_RELEASE_ARGS=
else ifeq ($(VCS_BRANCH),develop)
RELEASE_PUBLISH=true
endif
endif

# Done with `$(shell ...)`, echo recipe commands going forward
.SHELLFLAGS+= -x


## Top-level targets

.PHONY: all
### Default target
all: build

# Strive for as much consistency as possible in development tasks between the local host
# and inside containers.  To that end, most of the `*-docker` container target recipes
# should run the corresponding `*-local` local host target recipes inside the
# development container.  Top level targets, like `test`, should run as much as possible
# inside the development container.

.PHONY: build
### Set up everything for development from a checkout, local and in containers
build: ./.git/hooks/pre-commit build-local build-docker
.PHONY: build-local
### Set up for development locally, directly on the host
build-local: ./var/log/recreate.log
.PHONY: build-docker
### Set up for development in Docker containers
build-docker: ./var/log/docker-build.log
.PHONY: build-bump
### Bump the package version if on a branch that should trigger a release
build-bump: ~/.gitconfig ./var/log/recreate-build.log
ifeq ($(RELEASE_PUBLISH),true)
# Import the private signing key from CI secrets
	$(MAKE) ./var/log/gpg-import.log
endif
# Collect the versions involved in this release according to conventional commits
	cz_bump_args="--check-consistency --no-verify"
ifneq ($(VCS_BRANCH),master)
	cz_bump_args+=" --prerelease beta"
endif
ifeq ($(RELEASE_PUBLISH),true)
	cz_bump_args+=" --gpg-sign"
endif
	exit_code=0
	cz_bump_stdout=$$(./.tox/build/bin/cz bump $${cz_bump_args} --dry-run) ||
	    exit_code=$$?
	rm -fv "./var/cz-bump-no-release.txt"
	if (( $$exit_code == 3 || $$exit_code == 21 ))
	then
# No release necessary for the commits since the last release, don't publish a release
	    echo "true" >"./var/cz-bump-no-release.txt"
	    exit
	elif (( $$exit_code != 0 ))
	then
# Commitizen returned an unexpected exit status code, fail
	    exit $$exit_code
	fi
	next_version="$$(
	    echo "$${cz_bump_stdout}" |
	    sed -nE 's|bump: *version *(.+) *→ *(.+)|\2|p'
	)"
# Update the release notes/changelog
	git fetch origin "$(TOWNCRIER_COMPARE_BRANCH)"
	./.tox/build/bin/towncrier check \
	    --compare-with "origin/$(TOWNCRIER_COMPARE_BRANCH)"
	if ! git diff --cached --exit-code
	then
	    set +x
	    echo "CRITICAL: Cannot bump version with staged changes"
	    false
	fi
# Capture the release notes for *just this* release for creating the GitHub release.
# Have to run before the real `$ towncrier build` run without the `--draft` option
# because after that the `newsfragments` will have been deleted.
	./.tox/build/bin/towncrier build --version "$${next_version}" --draft --yes \
	    >"./NEWS-release.rst"
# Build and stage the release notes to be commited by `$ cz bump`
	./.tox/build/bin/towncrier build --version "$${next_version}" --yes
# Increment the version in VCS
	./.tox/build/bin/cz bump $${cz_bump_args}

.PHONY: start
### Run the local development end-to-end stack services in the background as daemons
start: build-docker
	docker compose down
	docker compose up -d
.PHONY: run
### Run the local development end-to-end stack services in the foreground for debugging
run: build-docker
	docker compose down
	docker compose up

.PHONY: check-push
### Perform any checks that should only be run before pushing
check-push: build-docker
ifeq ($(RELEASE_PUBLISH),true)
	./.tox/build/bin/towncrier check --compare-with "origin/develop"
endif

.PHONY: release
### Publish installable Python packages to PyPI and container images to Docker Hub
release: release-python
ifeq ($(DOCKER_PUSH),true)
	$(MAKE) release-docker
endif
.PHONY: release-python
### Publish installable Python packages to PyPI
release-python: \
		~/.pypirc ~/.local/bin/codecov \
		./var/log/docker-build.log ./var/log/recreate-build.log
# Upload any build or test artifacts to CI/CD providers
ifeq ($(GITLAB_CI),true)
	~/.local/bin/codecov -t "$(CODECOV_TOKEN)" --file "./coverage.xml"
endif
ifeq ($(RELEASE_PUBLISH),true)
# Import the private signing key from CI secrets
	$(MAKE) ./var/log/gpg-import.log
endif
# Build Python packages/distributions from the development Docker container for
# consistency/reproducibility.
	docker compose run --rm python-project-structure-devel \
	    ./.tox/py3/bin/pyproject-build -w
# https://twine.readthedocs.io/en/latest/#using-twine
	./.tox/build/bin/twine check ./dist/* ./.tox-docker/dist/*
	if [ ! -z "$$(git status --porcelain)" ]
	then
	    set +x
	    echo "CRITICAL: Checkout is not clean, not publishing release"
	    false
	fi
	if [ -e "./var/cz-bump-no-release.txt" ]
	then
	    exit
	fi
ifeq ($(RELEASE_PUBLISH),true)
# Publish from the local host outside a container for access to user credentials:
# https://twine.readthedocs.io/en/latest/#using-twine
# Only release on `master` or `develop` to avoid duplicate uploads
	./.tox/build/bin/twine upload -s -r "$(PYPI_REPO)" ./dist/* ./.tox-docker/dist/*
# The VCS remote shouldn't reflect the release until the release has been successfully
# published
ifneq ($(VCS_REMOTE_AUTH),)
# Requires a Personal or Project Access Token in the GitLab CI/CD Variables.  That
# variable value should be prefixed with the token name as a HTTP `user:password`
# authentication string:
# https://stackoverflow.com/a/73426417/624787
	git remote get-url "origin"
	echo $$(
	    git remote get-url "origin" |
	    sed -nE 's|(https?://)([^@/]+@\|)(.+)|\1secret@\3|p'
	)
	set +x
	git remote set-url "origin" "$$(
	    git remote get-url "origin" |
	    sed -nE 's|(https?://)([^/]+@\|)([^@/]+/.+)|\1$(VCS_REMOTE_AUTH)@\3|p'
	)"
	set -x
endif
	git push --no-verify --tags origin "HEAD:$(VCS_BRANCH)"
	current_version=$$(./.tox/build/bin/cz version --project)
ifeq ($(GITLAB_CI),true)
	docker compose run --rm gitlab-release-cli release-cli create \
	    --description "./NEWS-release.rst"
	    --tag-name "v$${current_version}"
# assets:
#   links:
#     - name: "Python `sdist` tarball"
#       url: TODO
#       filepath: ".tox/dist/*"
# Create a GitHub release
	gh release create "v$${current_version}" $(GITHUB_RELEASE_ARGS) \
	    --notes-file "./NEWS-release.rst" ./dist/* ./.tox-docker/dist/*
endif
endif
.PHONY: release-docker
### Publish container images to Docker Hub
release-docker: build-docker
# https://docs.docker.com/docker-hub/#step-5-build-and-push-a-container-image-to-docker-hub-from-your-computer
ifeq ($(CI),true)
	$(MAKE) ./var/log/docker-login.log
endif
	docker push -a "merpatterson/python-project-structure"
	docker compose run --rm docker-pushrm

.PHONY: format
### Automatically correct code in this checkout according to linters and style checkers
format: build-local
	./.tox/py3/bin/autoflake -r -i --remove-all-unused-imports \
		--remove-duplicate-keys --remove-unused-variables \
		--remove-unused-variables "./src/pythonprojectstructure/"
	./.tox/py3/bin/autopep8 -v -i -r "./src/pythonprojectstructure/"
	./.tox/py3/bin/black "./src/pythonprojectstructure/"

.PHONY: test
### Format the code and run the full suite of tests, coverage checks, and linters
test: build-docker
# Run from the development Docker container for consistency
	docker compose run --rm python-project-structure-devel make format test-local
.PHONY: test-local
### Run the full suite of tests on the local host
test-local: build-local
	tox
.PHONY: test-docker
### Run the full suite of tests inside a docker container
test-docker: build-docker
	docker compose run --rm python-project-structure-devel make test-local
# Ensure the dist/package has been correctly installed in the image
	docker compose run --rm python-project-structure \
	    python -m pythonprojectstructure --help
	docker compose run --rm python-project-structure python-project-structure --help
.PHONY: test-debug
### Run tests in the main/default environment and invoke the debugger on errors/failures
test-debug: ./var/log/editable.log
	./.tox/py3/bin/pytest --pdb

.PHONY: upgrade
### Update all fixed/pinned dependencies to their latest available versions
upgrade:
	touch "./pyproject.toml"
	$(MAKE) PUID=$(PUID) "test"
# Update VCS hooks from remotes to the latest tag.
	./.tox/build/bin/pre-commit autoupdate

.PHONY: clean
### Restore the checkout to a state as close to an initial clone as possible
clean:
	docker compose --remove-orphans down --rmi "all" -v || true
	./.tox/build/bin/pre-commit uninstall \
	    --hook-type "pre-commit" --hook-type "commit-msg" --hook-type "pre-push" \
	    || true
	./.tox/build/bin/pre-commit clean || true
	git clean -dfx -e "var/"
	rm -rfv "./var/log/"


## Utility targets

.PHONY: expand-template
## Create a file from a template replacing environment variables
expand-template: .SHELLFLAGS = -eu -o pipefail -c
expand-template: ./var/log/host-install.log
	if [ -e "$(target)" ]
	then
	    echo "WARNING: Template $(template) has been updated:"
	    echo "Reconcile changes and \`$$ touch $(target)\`:"
	    diff -u "$(target)" "$(template)" || true
	    false
	fi
	envsubst <"$(template)" >"$(target)"


## Real targets

./requirements.txt: ./pyproject.toml ./setup.cfg ./tox.ini ./requirements-build.txt.in
	$(MAKE) "./var/log/recreate-build.log"
ifeq ($(CI),true)
# Don't update dependencies in CI/CD so that the release of new versions don't break
# CI/CD runs.
	touch "$(@)"
else
# Only upgrade dependencies locally during local development to ensure changes in
# dependencies are reflected in the frozen versions and to notify developers that new
# versions are available.
	tox -e "build"
endif

./var/log/recreate.log: \
		./var/log/host-install.log \
		./requirements.txt ./requirements-devel.txt ./tox.ini
	mkdir -pv "$(dir $(@))"
# Prevent uploading unintended distributions
	rm -vf ./dist/* ./.tox/dist/* | tee -a "$(@)"
	tox -r --notest -v | tee -a "$(@)"
# Workaround tox's `usedevelop = true` not working with `./pyproject.toml`
./var/log/editable.log: ./var/log/recreate.log
	./.tox/py3/bin/pip install -e "./" | tee -a "$(@)"
./var/log/recreate-build.log: \
		./var/log/host-install.log ./requirements-build.txt ./tox.ini
	mkdir -pv "$(dir $(@))"
	tox -r -e "build" --notest -v | tee -a "$(@)"

# Docker targets
./var/log/docker-build.log: \
		./Dockerfile ./Dockerfile.devel ./.dockerignore \
		./requirements.txt ./requirements-devel.txt ./bin/entrypoint \
		./docker-compose.yml ./docker-compose.override.yml ./.env \
		./var/log/recreate-build.log
# Ensure access permissions to build artifacts in container volumes.
# If created by `# dockerd`, they end up owned by `root`.
	mkdir -pv "$(dir $(@))" "./var-docker/log/" "./.tox/" "./.tox-docker/" \
	    "./src/python_project_structure.egg-info/" \
	    "./src/python_project_structure-docker.egg-info/"
# Workaround issues with local images and the development image depending on the end
# user image.  It seems that `depends_on` isn't sufficient.
	current_version=$$(./.tox/build/bin/cz version --project)
	major_version=$$(echo $${current_version} | sed -nE 's|([0-9]+).*|\1|p')
	minor_version=$$(
	    echo $${current_version} | sed -nE 's|([0-9]+\.[0-9]+).*|\1|p'
	)
	docker buildx build --pull\
	    --tag "merpatterson/python-project-structure:$${current_version}"\
	    --tag "merpatterson/python-project-structure:$${minor_version}"\
	    --tag "merpatterson/python-project-structure:$${major_version}"\
	    --tag "merpatterson/python-project-structure:latest" "./" | tee -a "$(@)"
	docker compose build python-project-structure-devel | tee -a "$(@)"
# Prepare the testing environment and tools as much as possible to reduce development
# iteration time when using the image.
	docker compose run --rm python-project-structure-devel make build-local

# Local environment variables from a template
./.env: ./.env.in
	$(MAKE) "PUID=$(PUID)" "PGID=$(PGID)" \
	    "template=$(<)" "target=$(@)" expand-template

# Perform any one-time local checkout set up
./var/log/host-install.log:
	mkdir -pv "$(dir $(@))"
	(
	    if ! which pip
	    then
	        if which apk
	        then
	            apk update
	            apk add "gettext" "py3-pip" "gnupg" "github-cli"
	        else
	            sudo apt-get update
	            sudo apt-get install -y "gettext-base" "python3-pip" "gnupg" "gh"
	        fi
	    fi
	    which tox || pip install tox
	) | tee -a "$(@)"

./.git/hooks/pre-commit: ./var/log/recreate.log
	./.tox/build/bin/pre-commit install \
	    --hook-type "pre-commit" --hook-type "commit-msg" --hook-type "pre-push"

~/.local/bin/codecov:
	mkdir -pv "$(dir $(@))"
# https://docs.codecov.com/docs/codecov-uploader#using-the-uploader-with-codecovio-cloud
ifeq ($(UNAME_KERNEL_NAME),Darwin)
	curl --output-dir "$(dir $(@))" -Os \
	    "https://uploader.codecov.io/latest/macos/codecov"
else ifeq ($(UNAME_KERNEL_NAME),Linux)
ifeq ($(OS_ALPINE_VERSION),)
	curl --output-dir "$(dir $(@))" -Os \
	    "https://uploader.codecov.io/latest/linux/codecov"
else
	wget --directory-prefix="$(dir $(@))" \
	    "https://uploader.codecov.io/latest/alpine/codecov"
endif
else
	if $$(which "$(notdir $(@))")
	then
	    ln -v --backup=numbered $$(which "$(notdir $(@))") "$(@)"
	else
	    echo "Could not determine how to install Codecov uploader"
	fi
endif
	chmod +x "$(@)"

# Capture any project initialization tasks for reference.  Not actually usable.
 ./pyproject.toml:
	./.tox/build/bin/cz init

# Emacs editor settings
./.dir-locals.el: ./.dir-locals.el.in
	$(MAKE) "template=$(<)" "target=$(@)" expand-template

# User-created pre-requisites
~/.gitconfig:
	git config --global user.name "$(USER_FULL_NAME)"
	git config --global user.email "$(USER_EMAIL)"
~/.pypirc: ./home/.pypirc.in
	$(MAKE) "template=$(<)" "target=$(@)" expand-template
./var/log/docker-login.log:
	printenv "DOCKER_PASS" | docker login -u "merpatterson" --password-stdin |
	    tee -a "$(@)"

# GPG signing key creation and management in CI
export GPG_PASSPHRASE=
./var/ci-cd-signing-subkey.asc:
# We need a private key in the CI/CD environment for signing release commits and
# artifacts.  Use a subkey so that it can be revoked without affecting your main key.
# This recipe captures what I had to do to export a private signing subkey.  It's not
# widely tested so it should probably only be used for reference.  It worked for me but
# the risk is leaking your main private key so double and triple check all your
# assumptions and results.
# 1. Create a signing subkey with a NEW, SEPARATE passphrase:
#    https://wiki.debian.org/Subkeys#How.3F
# 2. Get the long key ID for that private subkey:
#	gpg --list-secret-keys --keyid-format "LONG"
# 3. Export *just* that private subkey and verify that the main secret key packet is the
#    GPG dummy packet and that the only other private key included is the intended
#    subkey:
#	gpg --armor --export-secret-subkeys "$(GPG_SIGNING_KEYID)!" |
#	    gpg --list-packets
# 4. Export that key as text to a file:
	gpg --armor --export-secret-subkeys "$(GPG_SIGNING_KEYID)!" >"$(@)"
# 5. Confirm that the exported key can be imported into a temporary GNU PG directory and
#    that temporary directory can then be used to sign files:
#	gnupg_homedir=$$(mktemp -d --suffix=".d" "gnupd.XXXXXXXXXX")
#	printenv 'GPG_PASSPHRASE' >"$${gnupg_homedir}/.passphrase"
#	gpg --homedir "$${gnupg_homedir}" --batch --import <"$(@)"
#	echo "Test signature content" >"$${gnupg_homedir}/test-sig.txt"
#	gpgconf --kill gpg-agent
#	gpg --homedir "$${gnupg_homedir}" --batch --pinentry-mode "loopback" \
#	    --passphrase-file "$${gnupg_homedir}/.passphrase" \
#	    --local-user "$(GPG_SIGNING_KEYID)!" --sign "$${gnupg_homedir}/test-sig.txt"
#	gpg --batch --verify "$${gnupg_homedir}/test-sig.txt.gpg"
# 6. Add the contents of this target as a `GPG_SIGNING_PRIVATE_KEY` secret in CI and the
# passphrase for the signing subkey as a `GPG_PASSPHRASE` secret in CI
./var/log/gpg-import.log:
# In each CI run, import the private signing key from the CI secrets
	printenv "GPG_SIGNING_PRIVATE_KEY" | gpg --batch --import | tee -a "$(@)"
	echo 'default-key:0:"$(GPG_SIGNING_KEYID)' | gpgconf —change-options gpg
	git config --global user.signingkey "$(GPG_SIGNING_KEYID)"
# "Unlock" the signing key for the remainder of this CI run:
	printenv 'GPG_PASSPHRASE' >"./var/ci-cd-signing-subkey.passphrase"
	true | gpg --batch --pinentry-mode "loopback" \
	    --passphrase-file "./var/ci-cd-signing-subkey.passphrase" \
	    --sign | gpg --list-packets
