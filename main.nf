#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/crisprvar
========================================================================================
 nf-core/crisprvar Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/crisprvar
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info"""
    =========================================
     nf-core/crisprvar v${workflow.manifest.version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/crisprvar --reads '*_R{1,2}.fastq.gz' --samplesheet samplesheet.csv -profile standard,docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      --samplesheet                 Comma-separated variable file containing a sample id, amplicon sequence, and guide sequence in each row
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: standard, conda, docker, singularity, awsbatch, test

    Options:
      --singleEnd                   Specifies that the input is single end reads
      --hdr                         Specifies that the input sample sheet contains expected_hdr_amplicon_seq header
      --adapters                    Path to fasta file of adapter sequences
      --excel                       Specifies that input sample sheet is an .xslx rather than CSV file

    QC:
      --skipQC                      Skip all QC steps apart from MultiQC
      --skipFastQC                  Skip FastQC

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"
params.email = false
params.plaintext_email = false

multiqc_config = file(params.multiqc_config)
output_docs = file("$baseDir/docs/output.md")


// AWSBatch sanity checking
if(workflow.profile == 'awsbatch'){
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    if (!workflow.workDir.startsWith('s3') || !params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for workDir and outdir parameters on AWSBatch!"
}
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the above in a process, define the following:
//   input:
//   file fasta from fasta
//


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

// Check workDir/outdir paths to be S3 buckets if running on AWSBatch
// related: https://github.com/nextflow-io/nextflow/issues/813
if( workflow.profile == 'awsbatch') {
    if(!workflow.workDir.startsWith('s3:') || !params.outdir.startsWith('s3:')) exit 1, "Workdir or Outdir not on S3 - specify S3 Buckets for each to run on AWSBatch!"
}

/*
 * Create a channel for input read files
 */
 if(params.readPaths){
     if(params.singleEnd){
         Channel
             .from(params.readPaths)
             .map { row -> [ row[0], [file(row[1][0])]] }
             .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
             .into { raw_reads_fastqc; raw_reads_trimgalore }
     } else {
         Channel
             .from(params.readPaths)
             .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
             .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
             .into { raw_reads_fastqc; raw_reads_trimgalore }
     }
 } else {
     Channel
         .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
         .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
         .into { raw_reads_fastqc; raw_reads_trimgalore }
 }

if (params.samplesheet){
  original_samplesheet_ch = Channel
      .fromPath(params.samplesheet)
      .ifEmpty{ exit 1, "Cannot find samplesheet file: ${params.samplesheet}" }
} else {
  exit 1, "Must provide a samplesheet csv or Excel file"
}

 /*
  * PREPROCESSING - Remove DOS line endings
  */
if (!params.excel){
  process clean_samplesheet {
     tag "$name"
     publishDir "${params.outdir}/samplesheet", mode: 'copy'

     input:
     file samplesheet from original_samplesheet_ch

     output:
     file "samplesheet_cleaned.csv" into samplesheet_cleaned

     script:
     """
     dos2unix --newfile ${samplesheet} samplesheet_cleaned.csv
     """
  }
} else {
  process excel_to_csv {
     tag "$name"
     publishDir "${params.outdir}/samplesheet", mode: 'copy'

     input:
     file samplesheet from original_samplesheet_ch

     output:
     file "samplesheet_cleaned.csv" into samplesheet_cleaned, samplesheet_to_print

     script:
     """
     csvtk xlsx2csv ${samplesheet} > samplesheet_cleaned.csv
     """
  }
}

samplesheet_to_print
  .collect()
  .subscribe{ println it}

if (params.hdr){
  samplesheet_ch = samplesheet_cleaned
    .collect()
    .splitCsv(header:true)
    .map{ row -> tuple(row.sample_id, tuple(row.amplicon_seq, row.expected_hdr_amplicon_seq, row.guide_seq))}
    .ifEmpty { exit 1, "Cannot parse input samplesheet ${params.samplesheet}" }
} else {
  samplesheet_ch = samplesheet_cleaned
    .collect()
    .splitCsv(header:true)
    .map{ row -> tuple(row.sample_id, tuple(row.amplicon_seq, row.guide_seq))}
    .ifEmpty { exit 1, "Cannot parse input samplesheet ${params.samplesheet}" }
}

Channel.fromPath("$baseDir/assets/where_are_my_files.txt", checkIfExists: true)
       .into{ch_where_trim_galore; ch_where_star; ch_where_hisat2; ch_where_hisat2_sort}

// Define regular variables so that they can be overwritten
clip_r1 = params.clip_r1
clip_r2 = params.clip_r2
three_prime_clip_r1 = params.three_prime_clip_r1
three_prime_clip_r2 = params.three_prime_clip_r2
forwardStranded = params.forwardStranded
reverseStranded = params.reverseStranded
unStranded = params.unStranded


// Header log info
log.info """=======================================================
                                          ,--./,-.
          ___     __   __   __   ___     /,-._.--~\'
    |\\ | |__  __ /  ` /  \\ |__) |__         }  {
    | \\| |       \\__, \\__/ |  \\ |___     \\`-._,-`-,
                                          `._,._,\'

nf-core/crisprvar v${workflow.manifest.version}"
======================================================="""
def summary = [:]
summary['Pipeline Name']  = 'nf-core/crisprvar'
summary['Pipeline Version'] = workflow.manifest.version
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Fasta Ref']    = params.fasta
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Memory']   = params.max_memory
summary['Max CPUs']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Container Engine'] = workflow.containerEngine
if(workflow.containerEngine) summary['Container'] = workflow.container
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Working dir']    = workflow.workDir
summary['Output dir']     = params.outdir
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(workflow.profile == 'awsbatch'){
   summary['AWS Region'] = params.awsregion
   summary['AWS Queue'] = params.awsqueue
}
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


def create_workflow_summary(summary) {

    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-crisprvar-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/crisprvar Workflow Summary'
    section_href: 'https://github.com/nf-core/crisprvar'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}


/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    when:
    !params.skipQC && !params.skipFastQC

    input:
    set val(name), file(reads) from raw_reads_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}



/*
 * STEP 2 - Trim Galore!
 */
process trim_galore {
    label 'low_memory'
    tag "$name"
    publishDir "${params.outdir}/trim_galore", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("_fastqc") > 0) "FastQC/$filename"
            else if (filename.indexOf("trimming_report.txt") > 0) "logs/$filename"
            else if (!params.saveTrimmed && filename == "where_are_my_files.txt") filename
            else if (params.saveTrimmed && filename != "where_are_my_files.txt") filename
            else null
        }

    input:
    set val(name), file(reads) from raw_reads_trimgalore
    file wherearemyfiles from ch_where_trim_galore.collect()

    output:
    set val(name), file("*fq.gz") into trimmed_reads_crispresso
    file "*trimming_report.txt" into trimgalore_results
    file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports
    file "where_are_my_files.txt"


    script:
    c_r1 = clip_r1 > 0 ? "--clip_r1 ${clip_r1}" : ''
    c_r2 = clip_r2 > 0 ? "--clip_r2 ${clip_r2}" : ''
    tpc_r1 = three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${three_prime_clip_r1}" : ''
    tpc_r2 = three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${three_prime_clip_r2}" : ''
    nextseq = params.trim_nextseq > 0 ? "--nextseq ${params.trim_nextseq}" : ''
    if (params.singleEnd) {
        """
        trim_galore --fastqc --gzip $c_r1 $tpc_r1 $nextseq $reads
        """
    } else {
        """
        trim_galore --paired --fastqc --gzip $c_r1 $c_r2 $tpc_r1 $tpc_r2 $nextseq $reads
        """
    }
}



// Look up the guide RNA and amplicon sequence for each sample
crispresso_input = samplesheet_ch.join(trimmed_reads_crispresso)

/*
 * STEP 2 - CRISPResso
 */
process crispresso {
    tag "$name"
    publishDir "${params.outdir}/cripresso", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    input:
    set val(name), val(experiment_info), file(reads) from crispresso_input

    output:
    file "${name}"

    script:

    if (params.hdr){
      amplicon_wt = experiment_info[0]
      amplicon_hdr = experiment_info[1]
      guide = experiment_info[2]
      """
      CRISPResso -r1 ${reads[0]} \\
        -r2 ${reads[1]} \\
         --amplicon_seq $amplicon_wt \\
         --expected_hdr_amplicon_seq $amplicon_hdr \\
         --guide_seq $guide \\
         --output_folder ${name}
      """
    } else {
      amplicon = experiment_info[0]
      guide = experiment_info[1]
      """
      CRISPResso -r1 ${reads[0]} \\
        -r2 ${reads[1]} \\
         --amplicon_seq $amplicon \\
         --guide_seq $guide \\
         --output_folder ${name}
      """
    }
}


/*
 * STEP 3 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config
    file (fastqc:'fastqc/*') from fastqc_results.collect().ifEmpty([])
    file ('trimgalore/*') from trimgalore_results.collect()
    file ('software_versions/*') from software_versions_yaml
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/crisprvar] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/crisprvar] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/crisprvar] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/crisprvar] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/Documentation/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    log.info "[nf-core/crisprvar] Pipeline Complete"

}
