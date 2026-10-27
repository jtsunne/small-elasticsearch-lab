# es-single

One Elasticsearch node with authentication on, no node certificates, no published ports, and Caddy in front terminating TLS with an IP allowlist and a path allowlist. Includes the role and API key setup script and the expected results for the scenario checks.

Status: not yet written and not yet tested. The files for this scenario belong to plan task T3; until they exist, `make up SCENARIO=es-single` refuses to run.
