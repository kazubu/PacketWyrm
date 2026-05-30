# pktwyrm-tinet: lab-spec -> tinet topology generator.
#
# Pure Python (PyYAML only). No docker, no tinet binary, no FPGA needed
# to test — those tools are only required at lab run-time.

PYTHON ?= python3

.PHONY: test example clean

test:
	$(PYTHON) -m unittest discover -s tests -v

# Render the in-tree worked example into /tmp/lab-frr/ without actually
# running tinet. Useful as a smoke check before committing changes.
example:
	$(PYTHON) ./pktwyrm-tinet generate \
	    ../../configs/examples/lab-frr-2node/lab.yaml \
	    -o /tmp/lab-frr/

clean:
	rm -rf __pycache__ pktwyrm_tinet/__pycache__ tests/__pycache__
