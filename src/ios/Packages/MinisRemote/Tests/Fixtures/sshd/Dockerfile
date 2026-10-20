FROM alpine:3.20
RUN apk add --no-cache openssh bash \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash dev \
 && passwd -u dev \
 && mkdir -p /home/dev/.ssh \
 && chmod 700 /home/dev/.ssh
COPY authorized_keys /home/dev/.ssh/authorized_keys
RUN chown -R dev:dev /home/dev/.ssh && chmod 600 /home/dev/.ssh/authorized_keys
EXPOSE 22
# Alpine turns TCP forwarding off; the A3 screen tunnel tests need it.
CMD ["/usr/sbin/sshd", "-D", "-e", "-o", "AllowTcpForwarding=yes"]
