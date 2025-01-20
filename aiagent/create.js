const OpenAI = require('openai');
const { Account, ec, json, stark, RpcProvider, hash, CallData, Contract, cairo, byteArray, shortString, events, num, getChecksumAddress } = require('starknet');
const PREDICTION_ABI = require('./PD_ABI.json')
const axios = require('axios');
require('dotenv').config()

class NewsSelectionAgent {
    constructor(apiKey) {
        this.openai = new OpenAI({
            apiKey: apiKey,
            baseURL: process.env.AI_URL,
            defaultHeaders: { "x-foo": true }
        });

        this.newsSources = [
            {
                name: 'NewsAPI',
                url: 'https://newsapi.org/v2/top-headlines',
                params: {
                    country: 'us',
                    apiKey: process.env.NEWS_API_KEY,
                    // pageSize: 2
                }
            }
        ];
    }

    cleanJsonResponse(rawResponse) {
        try {
            const jsonStart = rawResponse.indexOf('{');
            const jsonEnd = rawResponse.lastIndexOf('}') + 1;

            if (jsonStart === -1 || jsonEnd === 0) {
                console.error('No JSON object found in response');
                return null;
            }

            const jsonStr = rawResponse.substring(jsonStart, jsonEnd);

            return JSON.parse(jsonStr);
        } catch (error) {
            console.error('JSON parsing error:', error);
            console.log('Raw response:', rawResponse);
            return null;
        }
    }

    async collectNews() {
        let allNews = [];

        for (const source of this.newsSources) {
            try {
                const response = await axios.get(source.url, {
                    params: source.params
                });


                const formattedNews = this.formatNewsResponse(response.data, source.name);
                allNews = [...allNews, ...formattedNews];

                console.log(`Successfully collected ${formattedNews.length} news from ${source.name}`);
            } catch (error) {
                console.error(`Error collecting news from ${source.name}:`, error.message);
            }
        }

        let sortNews = allNews.sort((a, b) => new Date(b.publishedAt) - new Date(a.publishedAt))

        console.log(sortNews);


        return sortNews;
    }

    formatNewsResponse(data, sourceName) {
        if (sourceName === 'NewsAPI') {
            return data.articles.map(article => ({
                title: article.title,
                description: article.description,
                url: article.url,
                source: article.source.name,
                publishedAt: article.publishedAt,
                originalSource: sourceName
            }));
        } else if (sourceName === 'Sina News API') {
            return data.newslist.map(news => ({
                title: news.title,
                description: news.description,
                url: news.url,
                source: 'Sina News',
                publishedAt: news.ctime,
                originalSource: sourceName
            }));
        }
        return [];
    }

    async analyzeNewsForPrediction(newsItems, targetCount = 2) {
        const simplifiedNews = newsItems.map((item, index) => ({
            id: index,
            title: item.title,
            description: item.description || "",
            source: item.source
        }));


        const systemPrompt = `You are a prediction market analyst. Evaluate news items for prediction markets. 
                                For each selected news item, you must determine:
                                1. A trading duration in hours (how long people can place predictions)
                                2. A settlement timestamp (when the outcome will be determined)
                                Choose reasonable durations based on the event type:
                                - Sports events: typically 24-48 hours for trading, settlement right after the event
                                - Political events: longer trading periods (72-168 hours), clear settlement dates
                                - Technology/Business announcements: medium trading periods (48-96 hours)`;

        const userPrompt = `Analyze ALL of these news items (${simplifiedNews.length} items) for prediction markets potential.
                                Then select the top ${targetCount} most suitable items.
                                
                                News items to analyze:
                                ${JSON.stringify(simplifiedNews, null, 2)}
                                
                                Return a JSON object with this exact structure:
                                {
                                    "evaluations": [
                                        {
                                            "id": number,
                                            "title": string,
                                            "scores": {
                                                "verifiability": number (0-10),
                                                "timeline": number (0-10),
                                                "publicInterest": number (0-10),
                                                "nonTriviality": number (0-10),
                                                "totalScore": number (sum of all scores)
                                            },
                                            "recommendation": string,
                                            "suggestedQuestion": string,
                                            "tradingDurationHours": number,
                                            "settlementTimestamp": string (ISO format timestamp)
                                        }
                                    ],
                                    "selectedIds": [array of ${targetCount} ids with highest total scores]
                                }
                                
                                For the settlementTimestamp, provide a specific ISO timestamp when the outcome will be known.
                                For tradingDurationHours, specify how many hours the market should remain open for predictions.`;


        try {
            const completion = await this.openai.chat.completions.create({
                messages: [
                    { role: "system", content: systemPrompt },
                    { role: "user", content: userPrompt }
                ],
                model: "claude-3-5-sonnet-20241022",
                response_format: { type: "json_object" },
                temperature: 0.5,
            });

            const rawResponse = completion.choices[0].message.content;

            const result = this.cleanJsonResponse(rawResponse);

            // console.log('rawResponse', result);
            // process.exit()

            let parsedResult = result

            const selectedNews = parsedResult.selectedIds
                .map(id => {
                    const newsItem = newsItems[id];
                    const evaluation = parsedResult.evaluations.find(e => e.id === id);
                    if (newsItem && evaluation) {
                        return {
                            originalNews: newsItem,
                            evaluation: evaluation
                        };
                    }
                    return null;
                })
                .filter(item => item !== null);

            return {
                fullEvaluation: parsedResult.evaluations,
                selectedNews: selectedNews
            };
        } catch (error) {
            console.error('Error in news analysis:', error);
            return null;
        }
    }

    formatResultsForDisplay(analysisResults) {
        if (!analysisResults || !analysisResults.fullEvaluation) {
            return {
                summary: "Error analysis",
                selectedMarkets: []
            };
        }

        const output = {
            summary: {
                totalAnalyzed: analysisResults.fullEvaluation.length,
                selectedCount: analysisResults.selectedNews.length,
            },
            selectedMarkets: analysisResults.selectedNews.map(item => ({
                title: item.originalNews.title,
                source: item.originalNews.source,
                publishedAt: item.originalNews.publishedAt,
                scores: item.evaluation.scores,
                recommendation: item.evaluation.recommendation,
                suggestedQuestion: item.evaluation.suggestedQuestion,
                tradingDurationHours: item.evaluation.tradingDurationHours,
                settlementTimestamp: item.evaluation.settlementTimestamp,
                contractParams: {
                    tradingDurationSeconds: item.evaluation.tradingDurationHours * 3600,
                    settlementUnixTimestamp: new Date(item.evaluation.settlementTimestamp).getTime() / 1000
                }
            }))
        };

        return output;
    }
}

async function demo() {
    const agent = new NewsSelectionAgent(process.env.API_KEY);
    const provider = new RpcProvider({ nodeUrl: 'https://starknet-sepolia.public.blastapi.io/rpc/v0_7' });

    const account = new Account(provider, process.env.ADDRESS, process.env.PK);

    const contract = new Contract(
        PREDICTION_ABI,
        process.env.PD_ADDRESS,
        account
    );

    const allNews = await agent.collectNews();
    // console.log(allNews);

    try {
        const analysis = await agent.analyzeNewsForPrediction(allNews);
        const formattedResults = agent.formatResultsForDisplay(analysis);

        console.log('news analysis result:');
        console.log(JSON.stringify(formattedResults, null, 2));


        for (const item of formattedResults.selectedMarkets) {
            try {
                console.log('Processing market:', item.suggestedQuestion);

                const params = [
                    item.suggestedQuestion,
                    item.contractParams.tradingDurationSeconds,
                    item.contractParams.settlementUnixTimestamp
                ];

                const myCall = contract.populate('create', params);
                console.log('Contract call params:', myCall);

                const { transaction_hash: txH } = await account.execute(
                    [myCall],
                    {
                        version: '0x1'
                    }
                );

                console.log('Transaction hash:', txH);

                await new Promise(resolve => setTimeout(resolve, 10000));
            } catch (error) {
                console.error('Error processing market:', item.suggestedQuestion);
                console.error('Error details:', error);
                continue;
            }
        }
    } catch (error) {
        console.error('error', error);
    }
}


demo()
