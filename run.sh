#!/usr/bin/bash

nextflow run ./wf_server_example.nf \
-ansi-log false \
-with-report \
--processing_server_address="localhost:8080" \
--rmq_address="localhost:5672" \
--rmq_username="mm-test" \
--rmq_password="mm-test" \
--mets="/home/mm/Desktop/wf_server_nf_script/example_ws/data/mets.xml" \
--input_file_grp="OCR-D-IMG" 

