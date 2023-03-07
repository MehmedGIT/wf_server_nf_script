@Grab(group='org.springframework.boot', module='spring-boot-starter-amqp', version='2.2.2.RELEASE')
import org.springframework.amqp.core.*
import org.springframework.amqp.rabbit.connection.CachingConnectionFactory
import org.springframework.amqp.rabbit.core.RabbitAdmin
import org.springframework.amqp.rabbit.listener.SimpleMessageListenerContainer
import org.springframework.amqp.rabbit.listener.api.*
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.lang.String;
import java.lang.Thread
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets;

import com.rabbitmq.client.CancelCallback
import com.rabbitmq.client.Channel;
import com.rabbitmq.client.Connection;
import com.rabbitmq.client.ConnectionFactory;
import com.rabbitmq.client.DefaultConsumer
import com.rabbitmq.client.DeliverCallback;

nextflow.enable.dsl=2

// These parameters can also be overwritten with values passed from the CLI
// when executing this script, i.e., --processing_server_address address
params.processing_server_address = "localhost:8080"
params.mets = "/home/mm/Desktop/example_ws/data/mets.xml"
// This is the entry point for the first ocr-d processor call in the Workflow
params.input_file_grp = "OCR-D-IMG"

params.rmq_address = "localhost:5672"
params.rmq_username = "mm-test"
params.rmq_password = "mm-test"
params.rmq_exchange = "ocrd-network-default"
rmq_uri = "amqp://${params.rmq_username}:${params.rmq_password}@${params.rmq_address}"

log.info """\
  O C R - D - W O R K F L O W - W E B A P I - 1
  ======================================================
  processing_server_address : ${params.processing_server_address}
  mets                      : ${params.mets}
  input_file_grp            : ${params.input_file_grp}
  rmq_uri                   : ${rmq_uri}
  """
  .stripIndent()


def produce_job_input_json(input_grp, output_grp, page_id, ocrd_params){
  // TODO: Using string builder should be more computationally efficient
  def json_body = """{"path": "${params.mets}","""
  if (input_grp != null)
    json_body = json_body + """ "input_file_grps": ["${input_grp}"]"""
  if (output_grp != null)
    json_body = json_body + """, "output_file_grps": ["${output_grp}"]"""
  if (page_id != null)
    json_body = json_body + """, "page_id": ${page_id}"""
  if (ocrd_params != null)
    json_body = json_body + """, "parameters": ${ocrd_params}"""
  else
    json_body = json_body + """, "parameters": {}"""

  json_body = json_body + """}"""
  return json_body
}

def post_processing_job(ocrd_processor, input_grp, output_grp, page_id, ocrd_params){
  def post_connection = new URL("http://${params.processing_server_address}/processor/${ocrd_processor}").openConnection()
  post_connection.setDoOutput(true)
  post_connection.setRequestMethod("POST")
  post_connection.setRequestProperty("accept", "application/json")
  post_connection.setRequestProperty("Content-Type", "application/json")

  def json_body = produce_job_input_json(input_grp, output_grp, page_id, ocrd_params)
  println(json_body)

  def httpRequestBodyWriter = new BufferedWriter(new OutputStreamWriter(post_connection.getOutputStream()))
  httpRequestBodyWriter.write(json_body)
  httpRequestBodyWriter.close()

  def response_code = post_connection.getResponseCode()
  println("Response code: " + response_code)
  if (response_code.equals(200)){
    def json = post_connection.getInputStream().getText()
    println("ResponseJSON: " + json)
  }
}

String parse_body(byte[] bytes) {
  if (bytes) {
    new String(bytes, Charset.forName('UTF-8'))
  }
}

String find_job_status(String message_body){
  // TODO: Use Regex
  if (message_body.contains("SUCCESS")){
    return "SUCCESS"
  } 
  else if (message_body.contains("FAILED")){
    return "FAILED"
  }
  else if (message_body.contains("RUNNING")){
    return "RUNNING"
  }
  else if (message_body.contains("QUEUED")){
    return "QUEUED"
  }
  else {
    return "NONE"
  }
}

def configure_and_consume_polling(result_queue_name){
  def ConnectionFactory factory = new ConnectionFactory();
  factory.setUri(rmq_uri);
  def com.rabbitmq.client.Connection rmq_connection = factory.newConnection();
  def com.rabbitmq.client.Channel rmq_channel = rmq_connection.createChannel();

  // rmq_channel.exchangeDeclare(params.rmq_exchange, "direct", true);
  rmq_channel.queueDeclare(result_queue_name, false, false, false, null);
  rmq_channel.queueBind(result_queue_name, params.rmq_exchange, params.rmq_exchange);

  def job_status = "NONE"
  try {
    while(true){
      def response = rmq_channel.basicGet(result_queue_name, true)
      if(response){
        println "Message received on ${new Date()}"
        def delivery_tag = response.getEnvelope().getDeliveryTag()
        println "Delivery tag: ${delivery_tag}"
        job_status = find_job_status(parse_body(response.getBody()))
        println "JobStatus: ${job_status}"
        println "Canceling polling for queue: ${result_queue_name}"
        break;
      }
      // This should be a higher value for production
      sleep(3)
    }
  } catch (Exception error) {
    println("Caught exception: ${error}")
  }

  return job_status
}

def exec_block_logic(ocrd_processor_str, input_dir, output_dir, page_id, ocrd_params){
  def String result_queue = "${ocrd_processor_str}-result"
  post_processing_job(ocrd_processor_str, input_dir, output_dir, null, null)
  def job_status = configure_and_consume_polling(result_queue)
  return job_status
}

process ocrd_cis_ocropy_binarize {
  maxForks 1

  input:
    val input_dir
    val output_dir

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-cis-ocropy-binarize", input_dir, output_dir, null, null)
    println "ocrd_cis_ocropy_binarize returning flag: ${job_status}"
}

process ocrd_anybaseocr_crop {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-anybaseocr-crop", input_dir, output_dir, null, null)
    println "ocrd_anybaseocr_crop returning flag: ${job_status}"
}

process ocrd_skimage_binarize {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-skimage-binarize", input_dir, output_dir, null, '{"method": "li"}')
    println "ocrd_skimage_binarize returning flag: ${job_status}"
}

process ocrd_skimage_denoise {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-skimage-denoise", input_dir, output_dir, null, '{"level-of-operation": "page"}')
    println "ocrd_skimage_denoise returning flag: ${job_status}"
}

process ocrd_tesserocr_deskew {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-tesserocr-deskew", input_dir, output_dir, null, '{"operation_level": "page"}')
    println "ocrd_tesserocr_deskew returning flag: ${job_status}"
}

process ocrd_cis_ocropy_segment {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-cis-ocropy-segment", input_dir, output_dir, null, '{"level-of-operation": "page"}')
    println "ocrd_cis_ocropy_segment returning flag: ${job_status}"
}

process ocrd_cis_ocropy_dewarp {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-cis-ocropy-dewarp", input_dir, output_dir, null, null)
    println "ocrd_cis_ocropy_dewarp returning flag: ${job_status}"
}

process ocrd_calamari_recognize {
  maxForks 1

  input:
    val input_dir
    val output_dir
    val prev_job_status

  when:
    prev_job_status == "SUCCESS"

  output:
    val output_dir
    val job_status

  exec:
    job_status = exec_block_logic("ocrd-calamari-recognize", input_dir, output_dir, null, '{"checkpoint_dir": "qurator-gt4histocr-1.0"}')
    println "ocrd_calamari_recognize returning flag: ${job_status}"
}

workflow {
  main:
    ocrd_cis_ocropy_binarize(params.input_file_grp, "OCR-D-BIN")
    ocrd_anybaseocr_crop(ocrd_cis_ocropy_binarize.out[0], "OCR-D-CROP", ocrd_cis_ocropy_binarize.out[1])
    ocrd_skimage_binarize(ocrd_anybaseocr_crop.out[0], "OCR-D-BIN2", ocrd_anybaseocr_crop.out[1])
    ocrd_skimage_denoise(ocrd_skimage_binarize.out[0], "OCR-D-BIN-DENOISE", ocrd_skimage_binarize.out[1])
    ocrd_tesserocr_deskew(ocrd_skimage_denoise.out[0], "OCR-D-BIN-DENOISE-DESKEW", ocrd_skimage_denoise.out[1])
    ocrd_cis_ocropy_segment(ocrd_tesserocr_deskew.out[0], "OCR-D-SEG", ocrd_tesserocr_deskew.out[1])
    ocrd_cis_ocropy_dewarp(ocrd_cis_ocropy_segment.out[0], "OCR-D-SEG-LINE-RESEG-DEWARP", ocrd_cis_ocropy_segment.out[1])
    ocrd_calamari_recognize(ocrd_cis_ocropy_dewarp.out[0], "OCR-D-OCR", ocrd_cis_ocropy_dewarp.out[1])
}
