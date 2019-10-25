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
// import hosted zone from Route53, this zone is linked to the registrated domain(pre-requisite)
data "aws_route53_zone" "domain_zone" {
  zone_id         = var.zone_id
  private_zone = false
}
// add domain name dns record for validation
resource "aws_route53_record" "validation" {
  name    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_type
  zone_id = data.aws_route53_zone.domain_zone.zone_id
  records = [aws_acm_certificate.cert.domain_validation_options[0].resource_record_value]
  ttl     = "60"
}
// record to point the domain name to the cdn
resource "aws_route53_record" "cloudfront" {
  name    = ""
  type    = "A"
  zone_id = data.aws_route53_zone.domain_zone.zone_id
  alias {
    name                   = aws_cloudfront_distribution.prd_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.prd_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

// ACM
// creates the certificate in us-east-1 for cdn
resource "aws_acm_certificate" "cert" {
    domain_name         = var.domain_name
    validation_method   = "DNS"
    provider            = aws.virginia
}
// to validate the certificate using the dns record
resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn           = aws_acm_certificate.cert.arn
  validation_record_fqdns   = [aws_route53_record.validation.fqdn]
  provider                  = aws.virginia
}



// IAM
// policy for S3
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [aws_s3_bucket.site_cdn_bucket.arn]
    principals {
      type        = "CanonicalUser"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity_s3.s3_canonical_user_id]
    }
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site_cdn_bucket.arn]
    principals {
      type        = "CanonicalUser"
      identifiers = [aws_cloudfront_origin_access_identity.origin_access_identity_s3.s3_canonical_user_id]
    }
  }
}

// S3
// bucket to be used by cloudfront as origin
resource "aws_s3_bucket" "site_cdn_bucket" {
  bucket = var.domain_name
  acl           = "private"
  force_destroy = true
}

// ORIGIN ACCESS IDENTITY
resource "aws_cloudfront_origin_access_identity" "origin_access_identity_s3" {
  comment = "Identity that is able to access S3"
}

// CLOUDFRONT
resource "aws_cloudfront_distribution" "prd_distribution" {
  origin {
    domain_name = var.domain_name
    origin_id   = "S3-${aws_s3_bucket.site_cdn_bucket.bucket}"
    s3_origin_config {
        origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity_s3.cloudfront_access_identity_path
        # origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity_s3.s3_canonical_user_id
    }
  }
  enabled = true
  // aliases for the distribution (extra cnames)
  aliases = ["synadia.engineering"]

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
    acm_certificate_arn = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method  = "sni-only"
  }
}
