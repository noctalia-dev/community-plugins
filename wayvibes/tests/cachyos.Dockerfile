# Clean, disposable package/build check. No host devices or desktop sockets are mounted.
FROM cachyos/cachyos@sha256:cc5ea38b26ea5b0dc7ea6464e0b028a2e2229c39b531e266828bb874c7ba9a9e

# Docker's default capabilities disallow the network namespace used by pacman
# hooks. This option applies only inside this disposable build container.
RUN sed -i '/^\[options\]$/a DisableSandboxNetwork' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed noctalia base-devel git cmake libevdev \
        nlohmann-json procps-ng coreutils python \
    && useradd -m tester

USER tester
WORKDIR /home/tester

# Pin reviewed sources; distro packages still follow the rolling CachyOS mirrors.
RUN git clone --revision=ff2042eef16c94bda6b14d6f87dc9287ab75bcf3 \
        https://github.com/sahaj-b/wayvibes.git wayvibes-engine \
    && (make -C wayvibes-engine > /tmp/wayvibes-build.log 2>&1 \
        || (cat /tmp/wayvibes-build.log; exit 1))

RUN git clone --revision=2a3d8937c19c8fd9f7b72b6ec9068c62760e6588 \
        https://github.com/luau-lang/luau.git luau \
    && cmake -S luau -B luau/build -DLUAU_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release \
    && cmake --build luau/build --target Luau.Repl.CLI -j 2

USER root
RUN install -Dm755 /home/tester/wayvibes-engine/wayvibes /usr/local/bin/wayvibes

COPY plugin.toml service.luau panel.luau widget.luau README.md CACHYOS.md COMMUNITY_REVIEW.md LICENSE thumbnail.webp /plugin/
COPY translations /plugin/translations
COPY tests /plugin/tests

USER tester
RUN mkdir -p /home/tester/.local/share/soundpacks \
    && cp -a wayvibes-engine/soundpacks/nk-cream /home/tester/.local/share/soundpacks/ \
    && test -f /home/tester/.local/share/soundpacks/nk-cream/config.json \
    && wayvibes --help \
    && noctalia --version \
    && noctalia plugins lint /plugin \
    && python /plugin/tests/run.py --luau /home/tester/luau/build/luau

CMD ["bash"]
