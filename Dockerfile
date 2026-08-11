FROM postgres:18-alpine

RUN apk add --no-cache --virtual build-deps make build-base py3-pip clang21 llvm21 && \
  pip install --break-system-packages pgxnclient && \
  pgxn install safeupdate && \
  echo "shared_preload_libraries=safeupdate" >> /usr/local/share/postgresql/postgresql.conf.sample && \
  apk del build-deps
