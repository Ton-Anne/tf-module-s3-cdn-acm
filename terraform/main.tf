//BASICS
// default provider (i.e. default region to deploy in)
provider "aws" {
  region  = "eu-central-1"
  version = "~> 2.23"
}

// optional second provider (only used when specified with a resource or data)
provider "aws" {
  alias   = "virginia"
  region  = "us-east-1"
  version = "~> 2.23"
}

// ACM
// creates the certificate in us-east-1 for cdn
resource "aws_acm_certificate" "default" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  provider          = aws.virginia
}

// ROUTE53
// to create DNS record for the certificate
data "aws_route53_zone" "external" {
  name = var.domain_name
}

// add domain name dns record for validation
resource "aws_route53_record" "validation" {
  name    = aws_acm_certificate.default.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.default.domain_validation_options[0].resource_record_type
  zone_id = data.aws_route53_zone.external.zone_id
  records = [aws_acm_certificate.default.domain_validation_options[0].resource_record_value]
  ttl     = "60"
}

// record to point the domain name to the cdn
resource "aws_route53_record" "cloudfront" {
  name    = ""
  type    = "A"
  zone_id = data.aws_route53_zone.external.zone_id
  alias {
    name                   = aws_cloudfront_distribution.prd_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.prd_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

// ACM AGAIN
// to validate the certificate using the dns record
resource "aws_acm_certificate_validation" "default" {
  certificate_arn         = aws_acm_certificate.default.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
  provider = aws.virginia
}

// NOTE: make sure to use the following line in cloudfront to make sure it waits for confirmation
// acm_certificate_arn      = "${aws_acm_certificate_validation.default.certificate_arn}"
// this is now already set

// S3
// website bucket. will be used by cloudfront as origin
// we will use the domain name as bucketname
resource "aws_s3_bucket" "prd_bucket" {
  bucket = var.domain_name
  acl           = "private"
  force_destroy = true
  website {
    index_document = "index.html"
    error_document = "error.html"
  }
  policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
    {
        "Sid": "PublicReadForGetBucketObjects",
        "Effect": "Allow",
        "Principal": {
            "AWS": "*"
         },
         "Action": "s3:GetObject",
         "Resource": "arn:aws:s3:::${var.domain_name}/*"
    }, {
        "Sid": "",
        "Effect": "Allow",
        "Principal": {
            "AWS": "*"
        },
        "Action": "s3:*",
        "Resource": [
            "arn:aws:s3:::${var.domain_name}",
            "arn:aws:s3:::${var.domain_name}/*"
        ]
    }]
}
EOF

}

// CLOUDFRONT
resource "aws_cloudfront_distribution" "prd_distribution" {
  origin {
    domain_name = aws_s3_bucket.prd_bucket.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.prd_bucket.bucket}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "match-viewer"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  // By default, show index.html file
  default_root_object = "index.html"

  // enable the distribution
  enabled = true

  // aliases for the distribution (extra cnames)
  aliases = ["synadia.engineering"]

  // If there is a 404, return index.html with a HTTP 200 Response
  custom_error_response {
    error_caching_min_ttl = 3000
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
  }

  // taget origin id must match the origin id above.
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.prd_bucket.bucket}"

    // Forward all query strings, cookies and headers
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    // Element to specify the protocol: allow-all, https-only, redirect-to-https
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  // Distributes content everywhere
  price_class = "PriceClass_All"

  // Restricts who is able to access this content
  restrictions {
    geo_restriction {
      // type of restriction, blacklist, whitelist or none
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
  bucket = aws_s3_bucket.prd_bucket.bucket
  key    = "index.html"
  source = var.index_path
  acl    = "public-read"
}

resource "aws_s3_bucket_object" "error" {
  bucket = aws_s3_bucket.prd_bucket.bucket
  key    = "error.html"
  source = var.error_path
  acl    = "public-read"
}
