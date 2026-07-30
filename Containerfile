FROM quay.io/fedora/fedora-minimal:latest
RUN microdnf install -y python3 python3-pip python3-pytest git gh && microdnf clean all
