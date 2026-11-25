# OpenSSH 9.7 test server for the TildeSSH integration tests (Alpine 3.20).
# One image, several roles (plain target, bastion, legacy-algorithms server) selected by environment variables.
FROM alpine:3.20

RUN apk add --no-cache openssh-server bash tmux \
 && mkdir -p /run/sshd

# Test accounts. Public keys come from the mounted /keys directory at start-up (see entrypoint.sh).
# The password is a throwaway value used only by the tests.
RUN for u in pwuser ed25519user ecdsauser rsauser; do \
      adduser -D -s /bin/bash "$u"; \
    done \
 && echo "pwuser:tilde-test-pw" | chpasswd

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
