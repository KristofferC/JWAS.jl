################################################################################
#MCMC for RR-BLUP, BayesC, BayesCπ and "conventional (no markers).
################################################################################
function MCMC_BayesianAlphabet(nIter,mme,df;
                     burnin                     = 0,
                     π                          = 0.0,
                     estimatePi                 = false,
                     estimateScale              = false,
                     sol                        = false,
                     outFreq                    = 1000,
                     methods                    = "BayesC",
                     output_samples_frequency   = 0,
                     update_priors_frequency    = 0,
                     output_file                = "MCMC_samples",
                     categorical_trait          = false)

    ############################################################################
    # Pre-Check
    ############################################################################
    #starting values for location parameters(no marker) are sol
    if categorical_trait == true
        #starting values for thresholds  -∞ < t1=0 < t2 < ... < t_{#category-1} < +∞
        # where t1=0 (must be fixed to center the distribution) and t_{#category-1}<1.
        #Then liabilities are sampled and stored in mme.ySparse
        category_obs  = map(Int,mme.ySparse) # categories (1,2,2,3,1...)
        ncategories = length(unique(category_obs))
        #-Inf,t1,t2,...,t_{#c-1},Inf
        thresholds = [-Inf;range(0, length=ncategories,stop=1)[1:(end-1)];Inf]

        cmean      = mme.X*sol #assume maker effects all zeros
        for i in 1:length(category_obs) #1,2,2,3,1...
            whichcategory = category_obs[i]
            mme.ySparse[i] = rand(TruncatedNormal(cmean[i], 1, thresholds[whichcategory],thresholds[whichcategory+1]))
        end
    end
    sol,α              = sol[1:size(mme.mmeLhs,1)],sol[(size(mme.mmeLhs,1)+1):end]
    solMean, solMean2  = zero(sol),zero(sol)
    ############################################################################
    # PRIORS / Working Variables
    ############################################################################
    #save posterior mean for residual variance
    if categorical_trait == false
        meanVare = meanVare2 = 0.0
    else
        mme.RNew = meanVare = meanVare2 = 1.0
    end
    #save poseterior mean for variances explained by polygenic effects (A) e.g Animal+ Maternal
    if mme.pedTrmVec != 0
       G0Mean,G0Mean2  = zero(mme.Gi),zero(mme.Gi)
    end
    #priors for marker effect variance
    if mme.M != 0
        mGibbs      = GibbsMats(mme.M.genotypes)
        nObs,nMarkers,mArray,mpm,M = mGibbs.nrows,mGibbs.ncols,mGibbs.xArray,mGibbs.xpx,mGibbs.X
        dfEffectVar = mme.df.marker
        if methods=="BayesL"
            mme.M.G /= 8 # in BayesL mme.M.G is the scale Matrix, Sigma, in the MTBayesLasso paper
        end
        meanVara,meanVara2 = 0.0,0.0 #variable to save variance for marker effect
        meanScaleVara,meanScaleVara2 = 0.0,0.0 #variable to save Scale parameter for prior of marker effect variance
        #vectors to save solutions for marker effects
        #α           = zeros(nMarkers)#starting values for marker effeccts are zeros
        #δ           = zeros(nMarkers)#inclusion indicator for marker effects
        δ           = ones(nMarkers)#inclusion indicator for marker effects
        meanAlpha,meanAlpha2 = zeros(nMarkers),zeros(nMarkers)#vectors to save solutions for marker effects
        meanDelta            = zeros(nMarkers)
        mean_pi,mean_pi2     = 0.0,0.0
        if methods=="BayesB" #α=β.*δ
            β              = copy(α)  ##partial marker effeccts
            locusEffectVar = fill(mme.M.G,nMarkers)
            mme.M.G        = locusEffectVar #mme.M.G is scalar for BayesC but a vector for BayeB
        end
        if methods=="BayesL"
           gammaDist  = Gamma(1, 8) # 8 is the scale parameter of the Gamma distribution (1/8 is the rate parameter)
           gammaArray = rand(gammaDist,nMarkers)
        end
    end

    ############################################################################
    #  WORKING VECTORS (ycor, saving values)
    ############################################################################
    #adjust y for starting values
    ycorr       = vec(Matrix(mme.ySparse)-mme.X*sol)
    if mme.M != 0 && α!=zero(α)
        ycorr = ycorr - M*α
    end
    ############################################################################
    #  SET UP OUTPUT MCMC samples
    ############################################################################
    if output_samples_frequency != 0
        outfile=output_MCMC_samples_setup(mme,nIter-burnin,output_samples_frequency,output_file)
    end

    ############################################################################
    # MCMC (starting values for sol (zeros);  mme.RNew; G0 are used)
    ############################################################################
    @showprogress "running MCMC for "*methods*"..." for iter=1:nIter

        if categorical_trait == true
            ########################################################################
            # 0. Categorical traits
            # 0.1 liabilities
            ########################################################################
            cmean = mme.ySparse - ycorr #liabilities - residuals
            for i in 1:length(category_obs) #1,2,2,3,1...
                whichcategory = category_obs[i]
                mme.ySparse[i] = rand(TruncatedNormal(cmean[i], 1, thresholds[whichcategory],thresholds[whichcategory+1]))
            end
            ########################################################################
            # 0. Categorical traits
            # 0.2 Thresholds
            ########################################################################
            #thresholds -∞,t1,t2,...,t_{categories-1},+∞
            #the threshold t1=0 must be fixed to center the distribution
            for i in 3:(length(thresholds)-1) #e.g., t2 between categories 2 and 3
                lowerboundry  = maximum(mme.ySparse[category_obs .== (i-1)])
                upperboundry  = minimum(mme.ySparse[category_obs .== i])
                thresholds[i] = rand(Uniform(lowerboundry,upperboundry))
            end
            ycorr = mme.ySparse - cmean
        end
        ########################################################################
        # 1.1. Non-Marker Location Parameters
        ########################################################################
        ycorr = ycorr + mme.X*sol
        rhs = mme.X'ycorr

        Gibbs(mme.mmeLhs,sol,rhs,mme.RNew)

        ycorr = ycorr - mme.X*sol
        ########################################################################
        # 1.2 Marker Effects
        ########################################################################
        if mme.M !=0
            if methods=="BayesC"
                nLoci = sampleEffectsBayesC!(mArray, mpm, ycorr, α, δ,mme.RNew, mme.M.G, π)
            elseif methods=="RR-BLUP"
                sampleEffectsBayesC0!(mArray,mpm,ycorr,α,mme.RNew,mme.M.G)
                nLoci = nMarkers
            elseif methods=="BayesB"
                nLoci = sampleEffectsBayesB!(mArray,mpm,ycorr,α,β,δ,mme.RNew,locusEffectVar,π)
            elseif methods == "BayesL"
                sampleEffectsBayesL!(mArray,mpm,ycorr,α,gammaArray,mme.RNew,mme.M.G)
                nLoci = nMarkers
            end
            #sample Pi
            if estimatePi == true
                π = samplePi(nLoci, nMarkers)
            end
        end
        ########################################################################
        # 2.1 Genetic Covariance Matrix (Polygenic Effects) (variance.jl)
        ########################################################################
        if mme.pedTrmVec != 0
            sample_variance_pedigree(mme,sol)
            addA(mme)
        end
        ########################################################################
        # 2.2 varainces for (iid) random effects;not required(empty)=>jump out
        ########################################################################
        sampleVCs(mme,sol)
        addLambdas(mme)
        ########################################################################
        # 2.3 Residual Variance
        ########################################################################
        if categorical_trait == false
            mme.ROld = mme.RNew
            mme.RNew = sample_variance(ycorr, length(ycorr), mme.df.residual, mme.scaleRes)
        end
        ########################################################################
        # 2.4 Marker Effects Variance
        ########################################################################
        if mme.M != 0
            if !(methods in ["BayesB","BayesL"]) && mme.MCMCinfo.estimate_variance
                mme.M.G  = sample_variance(α, nLoci, mme.df.marker, mme.M.scale)
            elseif methods == "BayesB"
                for j=1:nMarkers
                    mme.M.G[j] = sample_variance(β[j],1,mme.df.marker, mme.M.scale)
                end
            elseif methods == "BayesL"
                ssq = 0.0
                for i=1:size(α,1)
                    ssq += α[i]^2/gammaArray[i]
                end
                mme.M.G = (ssq + mme.df.marker*mme.M.scale)/rand(Chisq(nLoci+mme.df.marker))
               # MH sampler of gammaArray (Appendix C in paper)
                sampleGammaArray!(gammaArray,α,mme.M.G)
            end
        end
        ########################################################################
        # 2.5 Update priors using posteriors (empirical)
        ########################################################################
        if update_priors_frequency !=0 && iter%update_priors_frequency==0
            if mme.M!=0 && methods != "BayesB"
                mme.M.scale   = meanVara*(mme.df.marker-2)/mme.df.marker
            end
            if mme.pedTrmVec != 0
                mme.scalePed  = G0Mean*(mme.df.polygenic - size(mme.pedTrmVec,1) - 1)
            end
            mme.scaleRes  =  meanVare*(mme.df.residual-2)/mme.df.residual
            println("\n Update priors from posteriors.")
        end
        ########################################################################
        # 2.6 sample Scale parameter in prior for marker effect variances
        ########################################################################
        if estimateScale == true
            a = size(mme.M.G,1)*mme.df.marker/2   + 1
            b = sum(mme.df.marker ./ (2*mme.M.G )) + 1
            mme.M.scale = rand(Gamma(a,1/b))
        end
        ########################################################################
        # 3.1 Save MCMC samples
        ########################################################################
        if iter>burnin && (iter-burnin)%output_samples_frequency == 0
            if mme.M != 0
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),π,α,mme.M.G,outfile)
            else
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),false,false,false,outfile)
            end

            nsamples = (iter-burnin)/output_samples_frequency
            solMean   += (sol - solMean)/nsamples
            solMean2  += (sol .^2 - solMean2)/nsamples
            meanVare  += (mme.RNew - meanVare)/nsamples
            meanVare2 += (mme.RNew .^2 - meanVare2)/nsamples

            if mme.pedTrmVec != 0
                G0Mean  += (inv(mme.Gi)  - G0Mean )/nsamples
                G0Mean2 += (inv(mme.Gi) .^2  - G0Mean2 )/nsamples
            end
            if mme.M != 0
                meanAlpha  += (α - meanAlpha)/nsamples
                meanAlpha2 += (α .^2 - meanAlpha2)/nsamples
                meanDelta  += (δ - meanDelta)/nsamples

                if estimatePi == true
                    mean_pi += (π-mean_pi)/nsamples
                    mean_pi2 += (π .^2-mean_pi2)/nsamples
                end
                if methods != "BayesB"
                    meanVara += (mme.M.G - meanVara)/nsamples
                    meanVara2 += (mme.M.G .^2 - meanVara2)/nsamples
                end
                if estimateScale == true
                    meanScaleVara += (mme.M.scale - meanScaleVara)/nsamples
                    meanScaleVara2 += (mme.M.scale .^2 - meanScaleVara2)/nsamples
                end
            end
        end

        ########################################################################
        # 3.2 Printout
        ########################################################################
        if iter%outFreq==0 && iter>burnin
            println("\nPosterior means at iteration: ",iter)
            println("Residual variance: ",round(meanVare,digits=6))
            if mme.pedTrmVec !=0
                println("Polygenic effects covariance matrix \n",round.(G0Mean,digits=3))
            end
            if mme.M != 0
                if methods!="BayesB"
                    println("Marker effects variance: ",round(meanVara,digits=6))
                end
                if estimatePi == true
                    println("π: ", round(mean_pi,digits=3))
                end
            end
        end
    end

    ############################################################################
    # After MCMC
    ############################################################################
    if output_samples_frequency != 0
      for (key,value) in outfile
        close(value)
      end
    end
    output=output_result(mme,output_file,
                         solMean,meanVare,
                         mme.pedTrmVec!=0 ? G0Mean : false,
                         mme.M != 0 ? meanAlpha : false,
                         mme.M != 0 ? meanDelta : false,
                         mme.M != 0 ? meanVara : false,
                         mme.M != 0 ? estimatePi : false,
                         mme.M != 0 ? mean_pi : false,
                         mme.M != 0 ? estimateScale : false,
                         mme.M != 0 ? meanScaleVara : false,
                         solMean2,meanVare2,
                         mme.pedTrmVec!=0 ? G0Mean2 : false,
                         mme.M != 0 ? meanAlpha2 : false,
                         mme.M != 0 ? meanVara2 : false,
                         mme.M != 0 ? mean_pi2 : false,
                         mme.M != 0 ? meanScaleVara2 : false)
    return output
end
