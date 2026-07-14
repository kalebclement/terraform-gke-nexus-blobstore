# Nexus3 + the GCS blob store plugin
# Plugin: https://github.com/sonatype-nexus-community/nexus-blobstore-google-cloud
# pinned - plugin's archived, 0.61.0 only works with Nexus 3.64.0

ARG NEXUS_VERSION=3.64.0
FROM sonatype/nexus3:${NEXUS_VERSION}

ARG PLUGIN_VERSION=0.61.0
ARG BUNDLE_NAME=nexus-blobstore-google-cloud-${PLUGIN_VERSION}-bundle.kar
ARG KAR_URL=https://repo1.maven.org/maven2/org/sonatype/nexus/plugins/nexus-blobstore-google-cloud/${PLUGIN_VERSION}/${BUNDLE_NAME}

# karaf auto-installs any .kar dropped here
ADD --chown=nexus:nexus ${KAR_URL} /opt/sonatype/nexus/deploy/${BUNDLE_NAME}

USER nexus
