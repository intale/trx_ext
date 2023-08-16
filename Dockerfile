FROM postgres:15.4

RUN sed -i -e"s/^#default_transaction_isolation =.*$/default_transaction_isolation = 'serializable'/" /usr/share/postgresql/postgresql.conf.sample
