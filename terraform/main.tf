//PROVIDERS
// default provider (i.e. default region to deploy in)
provider "aws" {
  region  = "eu-central-1"
  version = "~> 2.23"
}
provider "aws" {
  alias   = "virginia"
  region  = "us-east-1"
  version = "~> 2.23"
}

// ROUTE53
// create hosted zone in Route53
resource "aws_route53_zone" "site" {
  name = var.domain_name
}
// add domain name dns record for validation
resource "aws_route53_record" "validation" {
  name    = aws_acm_certificate.default.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.default.domain_validation_options[0].resource_record_type
  zone_id = aws_route53_zone.site.zone_id
  records = [aws_acm_certificate.default.domain_validation_options[0].resource_record_value]
  ttl     = "60"
}
// record to point the domain name to the cdn
resource "aws_route53_record" "cloudfront" {
  name    = ""
  type    = "A"
  zone_id = aws_route53_zone.site.zone_id
  alias {
    name                   = aws_cloudfront_distribution.prd_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.prd_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

// ACM
// creates the certificate in us-east-1 for cdn
resource "aws_acm_certificate" "default" {
    domain_name = var.domain_name
    validation_method = "DNS"
    provider          = aws.virginia
}
// to validate the certificate using the dns record
resource "aws_acm_certificate_validation" "default" {
  certificate_arn         = aws_acm_certificate.default.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
  provider = aws.virginia
}



// IAM
// policy for S3
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [aws_s3_bucket.site_cdn_bucket.arn]

    principals {
      type        = "CanonicalUser"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity.s3_canonical_user_id]
    }
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site_cdn_bucket.arn]

    principals {
      type        = "CanonicalUser"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity.s3_canonical_user_id]
    }
  }
}





// S3
// bucket to be used by cloudfront as origin
resource "aws_s3_bucket" "site_cdn_bucket" {
  bucket = var.domain_name
  acl           = "private"
  force_destroy = true
  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}





// ORIGIN ACCESS IDENTITY
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "Only identity that is able to access the S3 bucket"
}





// CLOUDFRONT
resource "aws_cloudfront_distribution" "prd_distribution" {
  origin {
    domain_name = aws_s3_bucket.site_cdn_bucket.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.site_cdn_bucket.bucket}"
    s3_origin_config {
        origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }
  default_root_object = "index.html"
  enabled = true
  // aliases for the distribution (extra cnames)
  aliases = ["synadia.engineering"]
  custom_error_response {
    error_caching_min_ttl = 3000
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
  }
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.site_cdn_bucket.bucket}"
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }
  price_class = "PriceClass_All"
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  // SSL certificate for the service.
  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.default.certificate_arn
    ssl_support_method  = "sni-only"
  }
}

// S3 AGAIN
// to provide the index and error files in s3
// or use this location to implement a copy job to get your website files here
resource "aws_s3_bucket_object" "index" {
  bucket = aws_s3_bucket.site_cdn_bucket.bucket
  key    = "index.html"
  source = var.index_path
}

resource "aws_s3_bucket_object" "error" {
  bucket = aws_s3_bucket.site_cdn_bucket.bucket
  key    = "error.html"
  source = var.error_path
}
