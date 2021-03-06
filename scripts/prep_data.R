## requires libraries: parallel, doParallel, foreach, reshape, prodlim, Rsamtools

library(foreach)

load_lengths <- function(lengths_fname) {
  # load transcript lengths table
  ## length_fname: character; file path to transcript lengths file
  transcript_lengths <- read.table(lengths_fname, stringsAsFactors=F,
                                   col.names=c("transcript", "utr5_length", "cds_length", "utr3_length"))
  return(transcript_lengths)
}

load_fa <- function(transcript_fa_fname) {
  # load transcript sequences from genome .fa file
  ## transcripts_fa_fname: character; file path to transcriptome .fa file
  raw_text <- readLines(transcript_fa_fname)
  transcript_startLines <- grep(">", raw_text)
  num_transcripts <- length(transcript_startLines)
  transcript_names <- sapply(transcript_startLines,
                             function(x) {
                               gsub(">", "", strsplit(raw_text[x], split=" ")[[1]][1])
                             })
  transcript_startLines <- c(transcript_startLines, length(raw_text)+1) # add extra line for bookkeeping
  transcript_sequences <- sapply(1:num_transcripts,
                                 function(x) {
                                   startLine <- transcript_startLines[x]+1
                                   endLine <- transcript_startLines[x+1]-1
                                   transcriptSequence <- paste(raw_text[startLine:endLine], collapse="")
                                   return(transcriptSequence)
                                 })
  names(transcript_sequences) <- transcript_names
  return(transcript_sequences)
}

get_codons <- function(transcript_name, cod_idx, utr5_length, transcript_seq) {
  # return codons corresponding to A-, P-, and E-site 
  # for footprint originating from transcript_name and A site codon cod_idx
  ## transcript_name: character; correspond to names(transcript_seq)
  ## cod_idx: integer; codon index for A site codon
  ## utr5_legthn: integer; length of 5' utr region in transcript sequence
  ## transcript_seq: character vector; transcript (+ 5' and 3' UTR regions) sequences
  A_start <- utr5_length + 3*(cod_idx-1) + 1
  A_end <- utr5_length + 3*cod_idx
  A_codon <- substr(transcript_seq[transcript_name], A_start, A_end)
  P_start <- utr5_length + 3*(cod_idx-2) + 1
  P_end <- utr5_length + 3*(cod_idx-1)
  P_codon <- substr(transcript_seq[transcript_name], P_start, P_end)
  E_start <- utr5_length + 3*(cod_idx-3) + 1
  E_end <- utr5_length + 3*(cod_idx-2)
  E_codon <- substr(transcript_seq[transcript_name], E_start, E_end)
  codons <- c(A_codon, P_codon, E_codon)
  names(codons) <- c("A", "P", "E")
  return(codons)
}

get_bias_seq <- function(transcript_name, cod_idx, digest_length, utr5_length,
                         transcript_seq, bias_region, bias_length=2) {
  # get bias sequence at end of footprint
  ## transcript_name: character; transcript name, corresponds with item in names(transcript_seq)
  ## cod_idx: integer; index of A site codon
  ## digest_length: integer; d5 or d3 length between A site and footprint end
  ## utr5_length: integer; length of 5' UTR region (from lengths file)
  ## transcript_seq: character vector; transcript sequences (+ 5' and 3' UTR regions)
  ## bias_region: character; f5 or f3 (corresponding to 5' or 3' bias sequence)
  ## bias_length: integer; length of bias sequence
  if(bias_region=="f5") {
    seq_start <- utr5_length + 3*(cod_idx-1)+1 - digest_length
    seq_end <- seq_start + bias_length - 1
  } else {
    if(bias_region=="f3") {
      seq_end <- utr5_length + 3*cod_idx + digest_length
      seq_start <- seq_end - bias_length + 1
    }
  }
  bias_seq <- substr(transcript_seq[transcript_name], seq_start, seq_end)
  return(bias_seq)
}

init_data <- function(transcript_fa_fname, transcript_length_fname,
                      digest5_lengths=15:18, digest3_lengths=9:11, d5_d3_subsets=NULL, 
                      f5_length=2, f3_length=2, num_cores=NULL, which_transcripts=NULL) {
  # initialize data.frame for downstream GLM
  ## transcript_fa_fname: character; file path to transcriptome .fa file
  ## transcript_length_fname: character; file path to transcriptome lengths file
  ## digest5_lengths: integer vector; legal 5' digest lengths
  ## digest3_lengths: integer vector; legal 3' digest lengths
  ## d5_d3_subsets: data.frame; columns "d5" and "d3" of d5/d3 subsets to initiate data over
  ## bias_length: integer; length of bias sequence
  ## num_cores: integer; number of cores to parallelize over
  ## which_transcripts: character vector; transcripts selected for regression
  transcript_seq <- load_fa(transcript_fa_fname)
  transcript_length <- load_lengths(transcript_length_fname)
  if(!is.null(which_transcripts)) {
    transcript_seq <- transcript_seq[which_transcripts]
    transcript_length <- subset(transcript_length, transcript %in% which_transcripts)
  }
  transcript <- unlist(mapply(rep, x=transcript_length$transcript, times=transcript_length$cds_length/3))
  cod_idx <- unlist(lapply(transcript_length$cds_length/3, seq))
  if(is.null(num_cores)) {
    num_cores <- parallel::detectCores()-8
  }
  cl <- parallel::makeCluster(num_cores)
  doParallel::registerDoParallel(cl)
  codons <- foreach(a=transcript, b=cod_idx, 
                    c=transcript_length$utr5_len[match(transcript, transcript_length$transcript)],
                    .combine='rbind', .export=c("get_codons")) %dopar% {
                      get_codons(a, b, c, transcript_seq)
                    }
  if(!is.null(d5_d3_subsets)) {
    dat <- reshape::expand.grid.df(data.frame(transcript, cod_idx, codons), 
                                   d5_d3_subsets)
  } else {
    dat <- reshape::expand.grid.df(data.frame(transcript, cod_idx, codons),
                                   expand.grid(d5=digest5_lengths, d3=digest3_lengths))
  }
  dat$f5 <- foreach(a=as.character(dat$transcript), b=dat$cod_idx, c=dat$d5, 
                    d=transcript_length$utr5_length[match(dat$transcript, transcript_length$transcript)],
                    .combine='c', .export=c("get_bias_seq")) %dopar% { 
                      get_bias_seq(a, b, c, d, transcript_seq, "f5", f5_length)
                    }
  dat$f3 <- foreach(a=as.character(dat$transcript), b=dat$cod_idx, c=dat$d3,
                    d=transcript_length$utr3_length[match(dat$transcript, transcript_length$transcript)],
                    .combine='c', .export=c("get_bias_seq")) %dopar% {
                      get_bias_seq(a, b, c, d, transcript_seq, "f3", f3_length)
                    }
  bases <- c("A", "C", "T", "G")
  parallel::stopCluster(cl)
  dat$d5 <- as.factor(dat$d5)
  dat$d3 <- as.factor(dat$d3)
  dat$f5 <- as.factor(dat$f5)
  dat$f3 <- as.factor(dat$f3)
  dat$count <- 0
  return(dat)
}

load_offsets <- function(offsets_fname) {
  # load A site offset rules
  ## offsets_fname: character; file.path to offset / A site assignment rules .txt file
  ## rownames: footprint length
  ## colnames: frame (0, 1, 2)
  offsets <- read.table(offsets_fname, header=T)
  offsets <- data.frame(frame=as.vector(mapply(rep, 0:2, nrow(offsets))),
                        length=rep(as.numeric(rownames(offsets)), 3),
                        offset=c(offsets$frame_0, offsets$frame_1, offsets$frame_2))
  return(offsets)
}

load_bam <- function(bam_fname, transcript_length_fname, offsets_fname) {
  # calculate proportion of footprints within each 5' and 3' digest length combination
  ## bam_fname: character; file.path to .bam alignment file
  ## transcript_length_fname: character; file path to transcriptome lengths file
  ## offsets_fname: character; file.path to offset / A site assignment rules .txt file
  # read in footprints
  bam_file <- Rsamtools::BamFile(bam_fname)
  bam_param <- Rsamtools::ScanBamParam(tag=c("ZW", "MD"), 
                                       what=c("rname", "pos", "seq", "qwidth"))
  alignment <- data.frame(Rsamtools::scanBam(bam_file, param=bam_param)[[1]])
  num_footprints <- nrow(alignment)
  print(paste("Read in", num_footprints, "total footprints"))
  print(paste("... Removing", 
              sum(is.na(alignment$rname)), 
              paste0("(", round(sum(is.na(alignment$rname)) / num_footprints * 100, 1), "%)"),
              "unaligned footprints"))
  alignment <- subset(alignment, !is.na(alignment$rname))
  # assign 5' UTR lengths
  transcript_length <- load_lengths(transcript_length_fname)
  alignment$utr5_length <- transcript_length$utr5_length[match(alignment$rname, 
                                                               transcript_length$transcript)]
  # calculate frame
  alignment$frame <- (alignment$pos - alignment$utr5_length - 1) %% 3
  # calculate 5' and 3' digest lengths
  offsets <- load_offsets(offsets_fname)
  alignment$d5 <- offsets$offset[prodlim::row.match(alignment[,c("frame", "qwidth")], 
                                                    offsets[c("frame", "length")])]
  print(paste("... Removing", 
              sum(is.na(alignment$d5)), 
              paste0("(", round(sum(is.na(alignment$d5)) / num_footprints * 100, 1), "%)"), 
              "footprints outside A site offset definitions"))
  alignment <- subset(alignment, !is.na(alignment$d5))
  # calculate 3' digest lengths
  alignment$d3 <- with(alignment, qwidth - d5 - 3)
  # calculate cod_idx, remove footprints mapped outside coding region
  alignment$cod_idx <- with(alignment, (pos + d5 - utr5_length + 2) / 3)
  alignment$cds_length <- transcript_length$cds_length[match(alignment$rname, 
                                                             transcript_length$transcript)]/3
  outside_cds <- ((alignment$cod_idx < 0) | (alignment$cod_idx > alignment$cds_length))
  print(paste("... Removing", 
              sum(outside_cds),
              paste0("(", round(sum(outside_cds) / num_footprints * 100, 1), "%)"), 
              "footprints outside CDS"))
  alignment <- subset(alignment, !outside_cds)
  # return data
  alignment <- alignment[, c("rname", "cod_idx", "d5", "d3", "seq", "tag.ZW")]
  colnames(alignment) <- c("transcript", "cod_idx", "d5", "d3", "seq", "count")
  return(alignment)
}

count_d5_d3 <- function(bam_dat, plot_title="") {
  # count number of footprints per d5/d3 combination
  ## bam_dat: data.frame; output from load_bam()
  ## plot_title: character; plot title for output heatmap
  subset_count <- aggregate(count ~ d5 + d3, data=bam_dat, FUN=sum)
  subset_count <- subset_count[order(subset_count$count, decreasing=T),]
  subset_count$proportion <- sapply(seq(nrow(subset_count)),
                                    function(x) {
                                      sum(subset_count$count[1:x])/sum(subset_count$count)
                                    })
  subset_count_plot <- ggplot(subset_count, aes(x=d5, y=d3, fill=count)) + geom_tile(col="black") + 
    scale_fill_gradient(low="white", high="blue", name="Count") + theme_classic() + 
    geom_text(aes(label=paste0(round(count/sum(count)*100, 1), "%"))) + 
    ggtitle(plot_title) + xlab("5' digestion length") + ylab("3' digestion length")
  return(list(counts=subset_count, plot=subset_count_plot))
}

count_footprints <- function(bam_dat, regression_data) {
  # count up footprints by transcript, A site, and digest lengths
  ## bam_dat: data.frame; output from load_bam()
  ## regression_data: data.frame; output from init_data()
  # count up footprints
  bam_dat <- subset(bam_dat, transcript %in% levels(regression_data$transcript))
  alignments <- aggregate(count ~ transcript + cod_idx + d5 + d3, data=bam_dat, FUN=sum)
  # add counts to regression data.frame
  features <- c("transcript", "cod_idx", "d5", "d3")
  match_rows <- prodlim::row.match(alignments[, features], regression_data[, features])
  alignments <- subset(alignments, !is.na(match_rows))
  match_rows <- match_rows[!is.na(match_rows)]
  regression_data$count[match_rows] <- alignments$count
  return(regression_data)
}


# archive -----------------------------------------------------------------

plot_profile <- function(regression_data, transcript_id, model_fit=NULL) {
  # plot ribosome profile (aggregated counts per codon position) for a transcript
  ## regression_data: data.frame; output by init_data() and count_footprints()
  ## transcript_id: character; name of transcript to be plotted
  ## model_fit: glm() object; output from performing regression
  # count up footprints per codon position
  data_subset <- subset(regression_data, transcript==transcript_id)
  data_subset_cts <- aggregate(count ~ transcript + cod_idx, data=data_subset, FUN=sum)
  data_subset_cts$type <- "data"
  # plot profile
  if(is.null(model_fit)) {
    profile_plot <- ggplot2::ggplot(data_subset_cts, aes(x=cod_idx, y=count)) + geom_line() +
      theme_bw() + xlab("codon position") + ylab("footprint count") + ggtitle(transcript_id)
  } else {
    data_pred <- predict(model_fit, newdata=data_subset, type="response")
    data_pred_cts <- cbind(data_subset, data_pred)
    data_pred_cts <- aggregate(data_pred ~ transcript + cod_idx, data=data_pred_cts, FUN=sum)
    data_pred_cts$type <-
      data_subset_cts$pred <- data_pred_cts$data_pred[prodlim::row.match(data_pred_cts[,c("transcript", "cod_idx")],
                                                                         data_subset_cts[,c("transcript", "cod_idx")])]
    data_subset_cts$type <- "model prediction"
    profile_plot <- ggplot2::ggplot(data_subset_cts) +
      geom_line(aes(x=cod_idx, y=count), col="black") +
      geom_line(aes(x=cod_idx, y=pred), col="red", alpha=0.5) +
      theme_bw() + xlab("codon position") + ylab("footprint count") + ggtitle(transcript_id) + labs(colour="")
  }
  return(profile_plot)
}
